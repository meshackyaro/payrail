// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {Ownable, Ownable2Step} from "openzeppelin-contracts/access/Ownable2Step.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title InvoiceRegistry
/// @notice USDC-denominated invoices for cross-border B2B payments on Arc.
///
/// @dev Design notes:
///
///      - **No custody.** Payments move directly from payer to issuer in the
///        same call. This contract never holds funds, which keeps the blast
///        radius of a bug to allowances rather than balances. Use
///        {PaymentEscrow} when funds must be held against delivery.
///
///      - **Partial payments are allowed** by default, because B2B invoices are
///        routinely settled in tranches. An invoice is `Paid` only once
///        `amountPaid == amount`.
///
///      - **Amounts are `uint96`.** USDC has 6 decimals, so `uint96` covers
///        ~7.9e22 USDC -- far beyond any real invoice -- and lets an invoice
///        pack into fewer storage slots.
///
///      - **Metadata is reference-only.** `invoiceRef`, `purchaseOrder`, and
///        `documentHash` are hashes or opaque ERP identifiers. Do not put
///        counterparty PII on-chain.
contract InvoiceRegistry is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Open,
        Paid,
        Cancelled
    }

    /// @dev Packed to 6 slots. Field order is load-bearing -- reordering costs gas.
    struct Invoice {
        // slot 0: 20 + 5 + 5 + 1 = 31 bytes
        address issuer;
        uint40 dueDate;
        uint40 createdAt;
        Status status;
        // slot 1: 20 + 12 = 32 bytes
        address payer;
        uint96 amount;
        // slot 2: 12 + 1 = 13 bytes
        uint96 amountPaid;
        bool requiresVerifiedPayer;
        // slots 3-5
        bytes32 invoiceRef;
        bytes32 purchaseOrder;
        bytes32 documentHash;
    }

    /// @notice Off-chain references attached to an invoice for audit trails.
    struct Metadata {
        bytes32 invoiceRef;
        bytes32 purchaseOrder;
        bytes32 documentHash;
    }

    /// @notice The settlement token. Immutable: a registry is single-currency by
    ///         construction, so EURC support means deploying a second registry.
    IERC20 public immutable settlementToken;

    /// @notice Source of counterparty KYC attestations.
    IComplianceRegistry public complianceRegistry;

    /// @dev Invoice ids start at 1 so that `0` is an unambiguous "no invoice".
    uint256 private _nextInvoiceId = 1;

    mapping(uint256 invoiceId => Invoice) private _invoices;

    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed issuer,
        address indexed payer,
        uint96 amount,
        uint40 dueDate,
        bool requiresVerifiedPayer,
        bytes32 invoiceRef,
        bytes32 purchaseOrder,
        bytes32 documentHash
    );
    event InvoicePaid(
        uint256 indexed invoiceId,
        address indexed payer,
        uint96 amount,
        uint96 amountPaid,
        uint96 amountRemaining
    );
    event InvoiceSettled(uint256 indexed invoiceId, address indexed issuer, uint96 totalPaid);
    event InvoiceCancelled(uint256 indexed invoiceId, address indexed issuer);
    event ComplianceRegistryUpdated(address indexed previous, address indexed current);

    error ZeroAddress();
    error ZeroAmount();
    error DueDateInPast(uint40 dueDate, uint256 currentTime);
    error InvoiceNotFound(uint256 invoiceId);
    error InvoiceNotOpen(uint256 invoiceId, Status status);
    error NotInvoiceIssuer(uint256 invoiceId, address caller);
    error PayerNotAuthorized(uint256 invoiceId, address caller, address expectedPayer);
    error PayerNotVerified(address payer);
    error Overpayment(uint256 invoiceId, uint96 attempted, uint96 remaining);
    error InvoiceAlreadyPartiallyPaid(uint256 invoiceId, uint96 amountPaid);
    error IssuerCannotBePayer();

    /// @param settlementToken_    USDC address on the target Arc network.
    /// @param complianceRegistry_ Compliance registry used for KYC-gated invoices.
    /// @param owner_              Contract owner (pause control, registry updates).
    constructor(address settlementToken_, address complianceRegistry_, address owner_) Ownable(owner_) {
        if (settlementToken_ == address(0) || complianceRegistry_ == address(0)) revert ZeroAddress();
        settlementToken = IERC20(settlementToken_);
        complianceRegistry = IComplianceRegistry(complianceRegistry_);
    }

    // -------------------------------------------------------------------------
    // Issuer actions
    // -------------------------------------------------------------------------

    /// @notice Create an invoice payable in the settlement token.
    /// @param payer                 Expected counterparty, or `address(0)` to let
    ///                              anyone pay (useful for public payment links).
    /// @param amount                Total amount due, in token base units.
    /// @param dueDate               Unix timestamp the invoice falls due. Must be in the future.
    /// @param requiresVerifiedPayer When true, the payer must be `Verified` in the
    ///                              compliance registry at the time of payment.
    /// @return invoiceId The new invoice's id.
    function createInvoice(
        address payer,
        uint96 amount,
        uint40 dueDate,
        bool requiresVerifiedPayer,
        Metadata calldata metadata
    ) external whenNotPaused returns (uint256 invoiceId) {
        if (amount == 0) revert ZeroAmount();
        if (dueDate <= block.timestamp) revert DueDateInPast(dueDate, block.timestamp);
        if (payer == msg.sender) revert IssuerCannotBePayer();

        invoiceId = _nextInvoiceId++;

        _invoices[invoiceId] = Invoice({
            issuer: msg.sender,
            dueDate: dueDate,
            createdAt: uint40(block.timestamp),
            status: Status.Open,
            payer: payer,
            amount: amount,
            amountPaid: 0,
            requiresVerifiedPayer: requiresVerifiedPayer,
            invoiceRef: metadata.invoiceRef,
            purchaseOrder: metadata.purchaseOrder,
            documentHash: metadata.documentHash
        });

        emit InvoiceCreated(
            invoiceId,
            msg.sender,
            payer,
            amount,
            dueDate,
            requiresVerifiedPayer,
            metadata.invoiceRef,
            metadata.purchaseOrder,
            metadata.documentHash
        );
    }

    /// @notice Cancel an unpaid invoice.
    /// @dev Only permitted while `amountPaid == 0`. Once any value has moved to
    ///      the issuer there is nothing on-chain left to unwind, so cancelling
    ///      would misrepresent settlement state to the indexer and the ERP.
    function cancelInvoice(uint256 invoiceId) external {
        Invoice storage invoice = _requireInvoice(invoiceId);
        if (invoice.issuer != msg.sender) revert NotInvoiceIssuer(invoiceId, msg.sender);
        if (invoice.status != Status.Open) revert InvoiceNotOpen(invoiceId, invoice.status);
        if (invoice.amountPaid != 0) revert InvoiceAlreadyPartiallyPaid(invoiceId, invoice.amountPaid);

        invoice.status = Status.Cancelled;
        emit InvoiceCancelled(invoiceId, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Payer actions
    // -------------------------------------------------------------------------

    /// @notice Pay part of an invoice.
    /// @dev Caller must have approved this contract for at least `amount`.
    function pay(uint256 invoiceId, uint96 amount) public nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        Invoice storage invoice = _requireInvoice(invoiceId);
        if (invoice.status != Status.Open) revert InvoiceNotOpen(invoiceId, invoice.status);

        address expectedPayer = invoice.payer;
        if (expectedPayer != address(0) && expectedPayer != msg.sender) {
            revert PayerNotAuthorized(invoiceId, msg.sender, expectedPayer);
        }
        if (invoice.requiresVerifiedPayer && !complianceRegistry.isVerified(msg.sender)) {
            revert PayerNotVerified(msg.sender);
        }

        uint96 remaining = invoice.amount - invoice.amountPaid;
        if (amount > remaining) revert Overpayment(invoiceId, amount, remaining);

        uint96 newAmountPaid = invoice.amountPaid + amount;
        invoice.amountPaid = newAmountPaid;

        bool settled = newAmountPaid == invoice.amount;
        if (settled) invoice.status = Status.Paid;

        address issuer = invoice.issuer;

        // Effects are complete before the external call; `nonReentrant` is belt
        // and braces against a settlement token with transfer hooks.
        settlementToken.safeTransferFrom(msg.sender, issuer, amount);

        emit InvoicePaid(invoiceId, msg.sender, amount, newAmountPaid, remaining - amount);
        if (settled) emit InvoiceSettled(invoiceId, issuer, newAmountPaid);
    }

    /// @notice Pay an invoice's full outstanding balance.
    function payInFull(uint256 invoiceId) external {
        Invoice storage invoice = _requireInvoice(invoiceId);
        if (invoice.status != Status.Open) revert InvoiceNotOpen(invoiceId, invoice.status);
        pay(invoiceId, invoice.amount - invoice.amountPaid);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        return _requireInvoice(invoiceId);
    }

    /// @notice Outstanding balance on an invoice; `0` for settled or cancelled invoices.
    function amountRemaining(uint256 invoiceId) external view returns (uint96) {
        Invoice storage invoice = _requireInvoice(invoiceId);
        if (invoice.status != Status.Open) return 0;
        return invoice.amount - invoice.amountPaid;
    }

    /// @notice True when an open invoice is past its due date.
    function isOverdue(uint256 invoiceId) external view returns (bool) {
        Invoice storage invoice = _requireInvoice(invoiceId);
        return invoice.status == Status.Open && block.timestamp > invoice.dueDate;
    }

    /// @notice Id that the next created invoice will receive.
    function nextInvoiceId() external view returns (uint256) {
        return _nextInvoiceId;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setComplianceRegistry(address complianceRegistry_) external onlyOwner {
        if (complianceRegistry_ == address(0)) revert ZeroAddress();
        emit ComplianceRegistryUpdated(address(complianceRegistry), complianceRegistry_);
        complianceRegistry = IComplianceRegistry(complianceRegistry_);
    }

    /// @notice Halt invoice creation and payment. Cancellation stays available so
    ///         issuers are never trapped with open invoices during an incident.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _requireInvoice(uint256 invoiceId) private view returns (Invoice storage invoice) {
        invoice = _invoices[invoiceId];
        if (invoice.status == Status.None) revert InvoiceNotFound(invoiceId);
    }
}
