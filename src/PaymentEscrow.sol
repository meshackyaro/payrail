// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "openzeppelin-contracts/access/Ownable2Step.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title PaymentEscrow
/// @notice Holds USDC against a delivery obligation until the payer releases
///         it, the payee returns it, an arbiter resolves a dispute, or the
///         deadline passes and the payer reclaims.
///
/// @dev Design notes:
///
///      - **This contract takes custody**, unlike {InvoiceRegistry} and
///        {BatchPayout}. Funds sit here between {openEscrow} and settlement, so
///        every state transition writes status before transferring, and every
///        externally reachable path is `nonReentrant`.
///
///      - **Pausing never traps funds.** `whenNotPaused` gates only
///        {openEscrow}. Release, refund, and expiry claims stay open while
///        paused -- an incident switch that locked customer money inside the
///        contract would be worse than the incident.
///
///      - **Escrows settle whole.** There is no partial release. Splitting a
///        deliverable means opening several escrows, which keeps each one's
///        state machine to a single irreversible transition.
///
///      - **The deadline is a payer's backstop**, not an expiry of the payee's
///        claim: after `releaseDeadline` the payer may reclaim, but the payer
///        can still release voluntarily, and an arbiter can still resolve.
contract PaymentEscrow is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Funded,
        Released,
        Refunded
    }

    /// @dev Packed to 4 slots.
    struct Escrow {
        // slot 0: 20 + 5 + 5 + 1 = 31 bytes
        address payer;
        uint40 createdAt;
        uint40 releaseDeadline;
        Status status;
        // slot 1: 20 + 12 = 32 bytes
        address payee;
        uint96 amount;
        // slot 2
        address arbiter;
        // slot 3
        bytes32 invoiceRef;
    }

    /// @notice The settlement token (USDC on Arc).
    IERC20 public immutable settlementToken;

    /// @dev Escrow ids start at 1 so `0` is an unambiguous "no escrow".
    uint256 private _nextEscrowId = 1;

    mapping(uint256 escrowId => Escrow) private _escrows;

    event EscrowOpened(
        uint256 indexed escrowId,
        address indexed payer,
        address indexed payee,
        uint96 amount,
        uint40 releaseDeadline,
        address arbiter,
        bytes32 invoiceRef
    );
    event EscrowReleased(uint256 indexed escrowId, address indexed payee, uint96 amount, address releasedBy);
    event EscrowRefunded(uint256 indexed escrowId, address indexed payer, uint96 amount, address refundedBy);

    error ZeroAddress();
    error ZeroAmount();
    error DeadlineInPast(uint40 releaseDeadline, uint256 currentTime);
    error EscrowNotFound(uint256 escrowId);
    error EscrowNotFunded(uint256 escrowId, Status status);
    error PayeeCannotBePayer();
    error ArbiterCannotBeParty();
    error NotAuthorizedToRelease(uint256 escrowId, address caller);
    error NotAuthorizedToRefund(uint256 escrowId, address caller);
    error NotPayer(uint256 escrowId, address caller);
    error DeadlineNotReached(uint256 escrowId, uint40 releaseDeadline, uint256 currentTime);

    /// @param settlementToken_ USDC address on the target Arc network.
    /// @param owner_           Contract owner (pause control only).
    constructor(address settlementToken_, address owner_) Ownable(owner_) {
        if (settlementToken_ == address(0)) revert ZeroAddress();
        settlementToken = IERC20(settlementToken_);
    }

    // -------------------------------------------------------------------------
    // Opening
    // -------------------------------------------------------------------------

    /// @notice Open and fund an escrow. Pulls `amount` from the caller.
    /// @param payee           Who receives the funds on release.
    /// @param amount          Amount held, in token base units.
    /// @param releaseDeadline After this timestamp the payer may reclaim via
    ///                        {claimExpired}. Must be in the future.
    /// @param arbiter         Optional third party who may resolve a dispute in
    ///                        either direction. `address(0)` for no arbiter.
    /// @param invoiceRef      Reference to the invoice or agreement this covers.
    /// @return escrowId       The new escrow's id.
    function openEscrow(
        address payee,
        uint96 amount,
        uint40 releaseDeadline,
        address arbiter,
        bytes32 invoiceRef
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        if (payee == address(0)) revert ZeroAddress();
        if (payee == msg.sender) revert PayeeCannotBePayer();
        if (amount == 0) revert ZeroAmount();
        if (releaseDeadline <= block.timestamp) revert DeadlineInPast(releaseDeadline, block.timestamp);
        if (arbiter == msg.sender || arbiter == payee) revert ArbiterCannotBeParty();

        escrowId = _nextEscrowId++;

        _escrows[escrowId] = Escrow({
            payer: msg.sender,
            createdAt: uint40(block.timestamp),
            releaseDeadline: releaseDeadline,
            status: Status.Funded,
            payee: payee,
            amount: amount,
            arbiter: arbiter,
            invoiceRef: invoiceRef
        });

        settlementToken.safeTransferFrom(msg.sender, address(this), amount);

        emit EscrowOpened(escrowId, msg.sender, payee, amount, releaseDeadline, arbiter, invoiceRef);
    }

    // -------------------------------------------------------------------------
    // Settlement
    // -------------------------------------------------------------------------

    /// @notice Release escrowed funds to the payee.
    /// @dev Callable by the payer (goods accepted) or the arbiter (dispute
    ///      resolved for the payee). Deliberately not gated on the deadline:
    ///      a payer may release late.
    function release(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = _requireFunded(escrowId);

        address arbiter = escrow.arbiter;
        if (msg.sender != escrow.payer && !(arbiter != address(0) && msg.sender == arbiter)) {
            revert NotAuthorizedToRelease(escrowId, msg.sender);
        }

        escrow.status = Status.Released;

        address payee = escrow.payee;
        uint96 amount = escrow.amount;

        settlementToken.safeTransfer(payee, amount);
        emit EscrowReleased(escrowId, payee, amount, msg.sender);
    }

    /// @notice Return escrowed funds to the payer.
    /// @dev Callable by the payee (cannot deliver) or the arbiter (dispute
    ///      resolved for the payer).
    function refund(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = _requireFunded(escrowId);

        address arbiter = escrow.arbiter;
        if (msg.sender != escrow.payee && !(arbiter != address(0) && msg.sender == arbiter)) {
            revert NotAuthorizedToRefund(escrowId, msg.sender);
        }

        escrow.status = Status.Refunded;

        address payer = escrow.payer;
        uint96 amount = escrow.amount;

        settlementToken.safeTransfer(payer, amount);
        emit EscrowRefunded(escrowId, payer, amount, msg.sender);
    }

    /// @notice Reclaim funds after the release deadline has passed.
    /// @dev Payer-only backstop against an unresponsive payee. Without it, an
    ///      abandoned escrow would hold the payer's money forever.
    function claimExpired(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = _requireFunded(escrowId);

        if (msg.sender != escrow.payer) revert NotPayer(escrowId, msg.sender);

        uint40 deadline = escrow.releaseDeadline;
        if (block.timestamp <= deadline) revert DeadlineNotReached(escrowId, deadline, block.timestamp);

        escrow.status = Status.Refunded;

        uint96 amount = escrow.amount;
        settlementToken.safeTransfer(msg.sender, amount);
        emit EscrowRefunded(escrowId, msg.sender, amount, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.status == Status.None) revert EscrowNotFound(escrowId);
        return escrow;
    }

    /// @notice True when a funded escrow is past its deadline and reclaimable.
    function isExpired(uint256 escrowId) external view returns (bool) {
        Escrow storage escrow = _escrows[escrowId];
        return escrow.status == Status.Funded && block.timestamp > escrow.releaseDeadline;
    }

    /// @notice Id that the next opened escrow will receive.
    function nextEscrowId() external view returns (uint256) {
        return _nextEscrowId;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Halt new escrows. Settlement paths stay open by design, so a
    ///         pause can never strand funds already in custody.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _requireFunded(uint256 escrowId) private view returns (Escrow storage escrow) {
        escrow = _escrows[escrowId];
        if (escrow.status == Status.None) revert EscrowNotFound(escrowId);
        if (escrow.status != Status.Funded) revert EscrowNotFunded(escrowId, escrow.status);
    }
}
