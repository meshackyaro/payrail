// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";

import {InvoiceRegistry} from "../../src/InvoiceRegistry.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {IERC20Errors} from "openzeppelin-contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";

contract InvoiceRegistryTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    InvoiceRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal officer = makeAddr("officer");
    address internal issuer = makeAddr("issuer");
    address internal payer = makeAddr("payer");
    address internal stranger = makeAddr("stranger");

    uint96 internal constant AMOUNT = 10_000e6; // 10,000 USDC
    uint40 internal dueDate;

    InvoiceRegistry.Metadata internal metadata = InvoiceRegistry.Metadata({
        invoiceRef: keccak256("INV-2026-0042"),
        purchaseOrder: keccak256("PO-88117"),
        documentHash: keccak256("invoice.pdf")
    });

    event InvoicePaid(
        uint256 indexed invoiceId,
        address indexed payer,
        uint96 amount,
        uint96 amountPaid,
        uint96 amountRemaining
    );
    event InvoiceSettled(uint256 indexed invoiceId, address indexed issuer, uint96 totalPaid);
    event InvoiceCancelled(uint256 indexed invoiceId, address indexed issuer);

    function setUp() public {
        vm.warp(1_700_000_000);
        dueDate = uint40(block.timestamp + 30 days);

        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(owner, officer);
        registry = new InvoiceRegistry(address(usdc), address(compliance), owner);

        usdc.mint(payer, 1_000_000e6);
        usdc.mint(stranger, 1_000_000e6);

        vm.prank(payer);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(stranger);
        usdc.approve(address(registry), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _createInvoice() internal returns (uint256) {
        return _createInvoice(payer, AMOUNT, false);
    }

    function _createInvoice(address payer_, uint96 amount_, bool requiresKyc) internal returns (uint256) {
        vm.prank(issuer);
        return registry.createInvoice(payer_, amount_, dueDate, requiresKyc, metadata);
    }

    function _verify(address account) internal {
        vm.prank(officer);
        compliance.setKycStatus(account, IComplianceRegistry.KycStatus.Verified, 0, keccak256("ok"));
    }

    // -------------------------------------------------------------------------
    // Creation
    // -------------------------------------------------------------------------

    function test_CreateInvoice() public {
        uint256 id = _createInvoice();
        assertEq(id, 1);
        assertEq(registry.nextInvoiceId(), 2);

        InvoiceRegistry.Invoice memory inv = registry.getInvoice(id);
        assertEq(inv.issuer, issuer);
        assertEq(inv.payer, payer);
        assertEq(inv.amount, AMOUNT);
        assertEq(inv.amountPaid, 0);
        assertEq(inv.dueDate, dueDate);
        assertEq(inv.createdAt, uint40(block.timestamp));
        assertEq(uint8(inv.status), uint8(InvoiceRegistry.Status.Open));
        assertFalse(inv.requiresVerifiedPayer);
        assertEq(inv.invoiceRef, metadata.invoiceRef);
        assertEq(inv.purchaseOrder, metadata.purchaseOrder);
        assertEq(inv.documentHash, metadata.documentHash);
    }

    function test_InvoiceIdsIncrement() public {
        assertEq(_createInvoice(), 1);
        assertEq(_createInvoice(), 2);
        assertEq(_createInvoice(), 3);
    }

    function test_CreateRevertsOnZeroAmount() public {
        vm.prank(issuer);
        vm.expectRevert(InvoiceRegistry.ZeroAmount.selector);
        registry.createInvoice(payer, 0, dueDate, false, metadata);
    }

    function test_CreateRevertsOnPastDueDate() public {
        uint40 past = uint40(block.timestamp - 1);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceRegistry.DueDateInPast.selector, past, block.timestamp));
        registry.createInvoice(payer, AMOUNT, past, false, metadata);
    }

    function test_CreateRevertsWhenIssuerIsPayer() public {
        vm.prank(issuer);
        vm.expectRevert(InvoiceRegistry.IssuerCannotBePayer.selector);
        registry.createInvoice(issuer, AMOUNT, dueDate, false, metadata);
    }

    // -------------------------------------------------------------------------
    // Payment
    // -------------------------------------------------------------------------

    function test_PayInFullSettlesAndTransfers() public {
        uint256 id = _createInvoice();

        vm.expectEmit(true, true, false, true, address(registry));
        emit InvoicePaid(id, payer, AMOUNT, AMOUNT, 0);
        vm.expectEmit(true, true, false, true, address(registry));
        emit InvoiceSettled(id, issuer, AMOUNT);

        vm.prank(payer);
        registry.payInFull(id);

        assertEq(usdc.balanceOf(issuer), AMOUNT, "issuer paid directly");
        assertEq(usdc.balanceOf(address(registry)), 0, "registry takes no custody");
        assertEq(uint8(registry.getInvoice(id).status), uint8(InvoiceRegistry.Status.Paid));
        assertEq(registry.amountRemaining(id), 0);
    }

    function test_PartialPaymentsAccumulate() public {
        uint256 id = _createInvoice();
        uint96 first = 4000e6;

        vm.prank(payer);
        registry.pay(id, first);

        assertEq(usdc.balanceOf(issuer), first);
        assertEq(registry.amountRemaining(id), AMOUNT - first);
        assertEq(uint8(registry.getInvoice(id).status), uint8(InvoiceRegistry.Status.Open));

        vm.prank(payer);
        registry.pay(id, AMOUNT - first);

        assertEq(usdc.balanceOf(issuer), AMOUNT);
        assertEq(uint8(registry.getInvoice(id).status), uint8(InvoiceRegistry.Status.Paid));
    }

    function test_PayRevertsOnOverpayment() public {
        uint256 id = _createInvoice();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceRegistry.Overpayment.selector, id, AMOUNT + 1, AMOUNT));
        registry.pay(id, AMOUNT + 1);
    }

    function test_PayRevertsOnZeroAmount() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        vm.expectRevert(InvoiceRegistry.ZeroAmount.selector);
        registry.pay(id, 0);
    }

    function test_PayRevertsForUnauthorizedPayer() public {
        uint256 id = _createInvoice();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceRegistry.PayerNotAuthorized.selector, id, stranger, payer)
        );
        registry.pay(id, AMOUNT);
    }

    function test_OpenInvoiceAcceptsAnyPayer() public {
        // payer == address(0) is a public payment link.
        uint256 id = _createInvoice(address(0), AMOUNT, false);

        vm.prank(stranger);
        registry.pay(id, AMOUNT);

        assertEq(usdc.balanceOf(issuer), AMOUNT);
    }

    function test_PayRevertsOnAlreadyPaidInvoice() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        registry.payInFull(id);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceRegistry.InvoiceNotOpen.selector, id, InvoiceRegistry.Status.Paid)
        );
        registry.pay(id, 1);
    }

    function test_PayRevertsWithoutAllowance() public {
        uint256 id = _createInvoice();

        vm.prank(payer);
        usdc.approve(address(registry), 0);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(registry), 0, AMOUNT
            )
        );
        registry.pay(id, AMOUNT);
    }

    function test_PayRevertsOnUnknownInvoice() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceRegistry.InvoiceNotFound.selector, 999));
        registry.pay(999, AMOUNT);
    }

    // -------------------------------------------------------------------------
    // KYC gating
    // -------------------------------------------------------------------------

    function test_KycGatedInvoiceRejectsUnverifiedPayer() public {
        uint256 id = _createInvoice(payer, AMOUNT, true);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceRegistry.PayerNotVerified.selector, payer));
        registry.pay(id, AMOUNT);
    }

    function test_KycGatedInvoiceAcceptsVerifiedPayer() public {
        uint256 id = _createInvoice(payer, AMOUNT, true);
        _verify(payer);

        vm.prank(payer);
        registry.pay(id, AMOUNT);
        assertEq(usdc.balanceOf(issuer), AMOUNT);
    }

    function test_SuspendedPayerBlockedMidStream() public {
        uint256 id = _createInvoice(payer, AMOUNT, true);
        _verify(payer);

        vm.prank(payer);
        registry.pay(id, 1000e6);

        // Compliance suspends the counterparty between tranches.
        vm.prank(officer);
        compliance.setKycStatus(payer, IComplianceRegistry.KycStatus.Suspended, 0, keccak256("sar"));

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceRegistry.PayerNotVerified.selector, payer));
        registry.pay(id, 1000e6);
    }

    // -------------------------------------------------------------------------
    // Cancellation
    // -------------------------------------------------------------------------

    function test_IssuerCanCancelUnpaidInvoice() public {
        uint256 id = _createInvoice();

        vm.expectEmit(true, true, false, true, address(registry));
        emit InvoiceCancelled(id, issuer);

        vm.prank(issuer);
        registry.cancelInvoice(id);

        assertEq(uint8(registry.getInvoice(id).status), uint8(InvoiceRegistry.Status.Cancelled));
        assertEq(registry.amountRemaining(id), 0);
    }

    function test_CancelRevertsForNonIssuer() public {
        uint256 id = _createInvoice();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(InvoiceRegistry.NotInvoiceIssuer.selector, id, stranger));
        registry.cancelInvoice(id);
    }

    function test_CancelRevertsAfterPartialPayment() public {
        uint256 id = _createInvoice();

        vm.prank(payer);
        registry.pay(id, 1e6);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceRegistry.InvoiceAlreadyPartiallyPaid.selector, id, uint96(1e6))
        );
        registry.cancelInvoice(id);
    }

    function test_CannotPayCancelledInvoice() public {
        uint256 id = _createInvoice();
        vm.prank(issuer);
        registry.cancelInvoice(id);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceRegistry.InvoiceNotOpen.selector, id, InvoiceRegistry.Status.Cancelled
            )
        );
        registry.pay(id, AMOUNT);
    }

    // -------------------------------------------------------------------------
    // Overdue
    // -------------------------------------------------------------------------

    function test_IsOverdue() public {
        uint256 id = _createInvoice();
        assertFalse(registry.isOverdue(id));

        vm.warp(dueDate);
        assertFalse(registry.isOverdue(id), "due date itself is not yet overdue");

        vm.warp(dueDate + 1);
        assertTrue(registry.isOverdue(id));
    }

    function test_PaidInvoiceIsNeverOverdue() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        registry.payInFull(id);

        vm.warp(dueDate + 365 days);
        assertFalse(registry.isOverdue(id));
    }

    function test_OverdueInvoiceIsStillPayable() public {
        // Late payment must remain possible -- an overdue invoice is a
        // collections problem, not a closed one.
        uint256 id = _createInvoice();
        vm.warp(dueDate + 10 days);

        vm.prank(payer);
        registry.payInFull(id);
        assertEq(usdc.balanceOf(issuer), AMOUNT);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function test_PauseBlocksCreateAndPay() public {
        uint256 id = _createInvoice();

        vm.prank(owner);
        registry.pause();

        vm.prank(issuer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.createInvoice(payer, AMOUNT, dueDate, false, metadata);

        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.pay(id, AMOUNT);
    }

    function test_CancelStillWorksWhilePaused() public {
        uint256 id = _createInvoice();

        vm.prank(owner);
        registry.pause();

        // Issuers must not be trapped with open invoices during an incident.
        vm.prank(issuer);
        registry.cancelInvoice(id);
        assertEq(uint8(registry.getInvoice(id).status), uint8(InvoiceRegistry.Status.Cancelled));
    }

    function test_OnlyOwnerCanPause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.pause();
    }

    function test_SetComplianceRegistry() public {
        ComplianceRegistry next = new ComplianceRegistry(owner, officer);

        vm.prank(owner);
        registry.setComplianceRegistry(address(next));
        assertEq(address(registry.complianceRegistry()), address(next));
    }

    function test_SetComplianceRegistryRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(InvoiceRegistry.ZeroAddress.selector);
        registry.setComplianceRegistry(address(0));
    }

    // -------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------

    function testFuzz_PartialPaymentsNeverExceedTotal(uint96 amount, uint96 firstTranche) public {
        amount = uint96(bound(amount, 2, 500_000e6));
        firstTranche = uint96(bound(firstTranche, 1, amount - 1));

        uint256 id = _createInvoice(payer, amount, false);

        vm.prank(payer);
        registry.pay(id, firstTranche);
        assertEq(registry.amountRemaining(id), amount - firstTranche);

        vm.prank(payer);
        registry.pay(id, amount - firstTranche);

        assertEq(usdc.balanceOf(issuer), amount);
        assertEq(registry.amountRemaining(id), 0);
        assertEq(uint8(registry.getInvoice(id).status), uint8(InvoiceRegistry.Status.Paid));
    }

    function testFuzz_CannotPayMoreThanOutstanding(uint96 amount, uint96 attempt) public {
        amount = uint96(bound(amount, 1, 500_000e6));
        attempt = uint96(bound(attempt, amount + 1, type(uint96).max));

        uint256 id = _createInvoice(payer, amount, false);
        usdc.mint(payer, attempt);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceRegistry.Overpayment.selector, id, attempt, amount));
        registry.pay(id, attempt);
    }
}
