// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {Ownable, Ownable2Step} from "openzeppelin-contracts/access/Ownable2Step.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title BatchPayout
/// @notice Pays many vendors or contractors from one payer in a single
///         transaction, with a per-payment reference for ERP reconciliation.
///
/// @dev Design notes:
///
///      - **No custody.** Each payment is a direct `transferFrom(payer,
///        recipient)`. Routing through this contract's own balance would cost
///        an extra transfer per batch *and* create a pooled balance worth
///        attacking. The payer approves this contract once.
///
///      - **Batches are atomic.** If any single transfer reverts, the whole
///        batch reverts and nothing settles. This is deliberate: a half-applied
///        payroll run is far worse to reconcile than one that plainly failed.
///
///        The practical consequence is that one un-payable recipient blocks the
///        batch -- most realistically a USDC-blacklisted address, or a contract
///        recipient that rejects transfers. Operators should validate recipients
///        off-chain before submitting, and split large runs into several batches
///        so one bad row cannot hold up an entire payroll cycle. If best-effort
///        semantics are ever needed, add them as a separate entrypoint rather
///        than weakening this one.
///
///      - **Batch size is capped** so that a run cannot be built that always
///        exceeds the block gas limit. Callers should still simulate: see
///        {previewTotal} for the amount side and `forge script` for gas.
contract BatchPayout is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @param recipient Vendor or contractor being paid.
    /// @param amount    Amount in token base units (USDC has 6 decimals).
    /// @param paymentRef Opaque per-payment reference (invoice id, PO number
    ///                   hash) echoed in the event for reconciliation.
    /// @dev `reference` is a reserved word in Solidity, hence `paymentRef`.
    struct Payment {
        address recipient;
        uint96 amount;
        bytes32 paymentRef;
    }

    /// @notice Upper bound on payments per batch.
    /// @dev Guards against constructing a batch that can never fit in a block.
    ///      Not a gas guarantee -- always simulate before submitting.
    uint256 public constant MAX_BATCH_SIZE = 256;

    /// @notice The settlement token (USDC on Arc).
    IERC20 public immutable settlementToken;

    /// @notice Source of counterparty KYC attestations.
    IComplianceRegistry public complianceRegistry;

    /// @dev Batch ids start at 1 so `0` is an unambiguous "no batch".
    uint256 private _nextBatchId = 1;

    event BatchExecuted(
        uint256 indexed batchId,
        address indexed payer,
        uint256 totalAmount,
        uint256 paymentCount,
        bool recipientsVerified,
        bytes32 batchRef
    );
    event PayoutSent(
        uint256 indexed batchId, address indexed recipient, uint96 amount, bytes32 indexed paymentRef
    );
    event ComplianceRegistryUpdated(address indexed previous, address indexed current);

    error ZeroAddress();
    error ZeroAmount(uint256 index);
    error EmptyBatch();
    error BatchTooLarge(uint256 size, uint256 maxSize);
    error InvalidRecipient(uint256 index);
    error RecipientNotVerified(uint256 index, address recipient);

    /// @param settlementToken_    USDC address on the target Arc network.
    /// @param complianceRegistry_ Compliance registry used for verified batches.
    /// @param owner_              Contract owner (pause control, registry updates).
    constructor(address settlementToken_, address complianceRegistry_, address owner_) Ownable(owner_) {
        if (settlementToken_ == address(0) || complianceRegistry_ == address(0)) revert ZeroAddress();
        settlementToken = IERC20(settlementToken_);
        complianceRegistry = IComplianceRegistry(complianceRegistry_);
    }

    // -------------------------------------------------------------------------
    // Payouts
    // -------------------------------------------------------------------------

    /// @notice Pay every recipient in `payments` from `msg.sender`.
    /// @dev Caller must have approved this contract for at least the batch total.
    /// @param payments        Recipients and amounts. Duplicated recipients are
    ///                        permitted -- two invoices to one vendor is normal.
    /// @param requireVerified When true, every recipient must be `Verified` in
    ///                        the compliance registry.
    /// @param batchRef        Opaque reference for the batch as a whole (e.g. a
    ///                        payroll run id), echoed in {BatchExecuted}.
    /// @return batchId        Id correlating this batch's events.
    /// @return totalAmount    Sum actually transferred.
    function executeBatch(Payment[] calldata payments, bool requireVerified, bytes32 batchRef)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 batchId, uint256 totalAmount)
    {
        uint256 count = payments.length;
        if (count == 0) revert EmptyBatch();
        if (count > MAX_BATCH_SIZE) revert BatchTooLarge(count, MAX_BATCH_SIZE);

        batchId = _nextBatchId++;

        IERC20 token = settlementToken;
        IComplianceRegistry registry = complianceRegistry;

        for (uint256 i; i < count;) {
            Payment calldata payment = payments[i];
            address recipient = payment.recipient;
            uint96 amount = payment.amount;

            if (recipient == address(0) || recipient == msg.sender) revert InvalidRecipient(i);
            if (amount == 0) revert ZeroAmount(i);
            if (requireVerified && !registry.isVerified(recipient)) {
                revert RecipientNotVerified(i, recipient);
            }

            totalAmount += amount;

            token.safeTransferFrom(msg.sender, recipient, amount);
            emit PayoutSent(batchId, recipient, amount, payment.paymentRef);

            unchecked {
                ++i;
            }
        }

        emit BatchExecuted(batchId, msg.sender, totalAmount, count, requireVerified, batchRef);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Sum of a batch, for allowance checks and dollar-denominated cost
    ///         estimation before submitting.
    /// @dev Pure and calldata-only, so the router can call it off-chain for free.
    function previewTotal(Payment[] calldata payments) external pure returns (uint256 totalAmount) {
        uint256 count = payments.length;
        for (uint256 i; i < count;) {
            totalAmount += payments[i].amount;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Id that the next executed batch will receive.
    function nextBatchId() external view returns (uint256) {
        return _nextBatchId;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setComplianceRegistry(address complianceRegistry_) external onlyOwner {
        if (complianceRegistry_ == address(0)) revert ZeroAddress();
        emit ComplianceRegistryUpdated(address(complianceRegistry), complianceRegistry_);
        complianceRegistry = IComplianceRegistry(complianceRegistry_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
