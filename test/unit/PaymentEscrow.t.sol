// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PaymentEscrow} from "../../src/PaymentEscrow.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";

contract PaymentEscrowTest is Test {
    MockUSDC internal usdc;
    PaymentEscrow internal escrow;

    address internal owner = makeAddr("owner");
    address internal payer = makeAddr("payer");
    address internal payee = makeAddr("payee");
    address internal arbiter = makeAddr("arbiter");
    address internal stranger = makeAddr("stranger");

    uint96 internal constant AMOUNT = 25_000e6; // 25,000 USDC
    uint40 internal deadline;

    bytes32 internal constant INVOICE_REF = keccak256("INV-2026-0099");

    event EscrowReleased(uint256 indexed escrowId, address indexed payee, uint96 amount, address releasedBy);
    event EscrowRefunded(uint256 indexed escrowId, address indexed payer, uint96 amount, address refundedBy);

    function setUp() public {
        vm.warp(1_700_000_000);
        deadline = uint40(block.timestamp + 14 days);

        usdc = new MockUSDC();
        escrow = new PaymentEscrow(address(usdc), owner);

        usdc.mint(payer, 1_000_000e6);

        vm.prank(payer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _open() internal returns (uint256) {
        return _open(arbiter);
    }

    function _open(address arbiter_) internal returns (uint256) {
        vm.prank(payer);
        return escrow.openEscrow(payee, AMOUNT, deadline, arbiter_, INVOICE_REF);
    }

    // -------------------------------------------------------------------------
    // Opening
    // -------------------------------------------------------------------------

    function test_OpenEscrowTakesCustody() public {
        uint256 id = _open();

        assertEq(id, 1);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT, "funds held by escrow");
        assertEq(usdc.balanceOf(payer), 1_000_000e6 - AMOUNT);

        PaymentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(e.payer, payer);
        assertEq(e.payee, payee);
        assertEq(e.amount, AMOUNT);
        assertEq(e.arbiter, arbiter);
        assertEq(e.releaseDeadline, deadline);
        assertEq(e.createdAt, uint40(block.timestamp));
        assertEq(e.invoiceRef, INVOICE_REF);
        assertEq(uint8(e.status), uint8(PaymentEscrow.Status.Funded));
    }

    function test_EscrowIdsIncrement() public {
        assertEq(_open(), 1);
        assertEq(_open(), 2);
        assertEq(escrow.nextEscrowId(), 3);
    }

    function test_OpenWithoutArbiter() public {
        uint256 id = _open(address(0));
        assertEq(escrow.getEscrow(id).arbiter, address(0));
    }

    function test_OpenRevertsOnZeroPayee() public {
        vm.prank(payer);
        vm.expectRevert(PaymentEscrow.ZeroAddress.selector);
        escrow.openEscrow(address(0), AMOUNT, deadline, arbiter, INVOICE_REF);
    }

    function test_OpenRevertsWhenPayeeIsPayer() public {
        vm.prank(payer);
        vm.expectRevert(PaymentEscrow.PayeeCannotBePayer.selector);
        escrow.openEscrow(payer, AMOUNT, deadline, arbiter, INVOICE_REF);
    }

    function test_OpenRevertsOnZeroAmount() public {
        vm.prank(payer);
        vm.expectRevert(PaymentEscrow.ZeroAmount.selector);
        escrow.openEscrow(payee, 0, deadline, arbiter, INVOICE_REF);
    }

    function test_OpenRevertsOnPastDeadline() public {
        uint40 past = uint40(block.timestamp - 1);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.DeadlineInPast.selector, past, block.timestamp));
        escrow.openEscrow(payee, AMOUNT, past, arbiter, INVOICE_REF);
    }

    function test_OpenRevertsWhenArbiterIsParty() public {
        vm.prank(payer);
        vm.expectRevert(PaymentEscrow.ArbiterCannotBeParty.selector);
        escrow.openEscrow(payee, AMOUNT, deadline, payer, INVOICE_REF);

        vm.prank(payer);
        vm.expectRevert(PaymentEscrow.ArbiterCannotBeParty.selector);
        escrow.openEscrow(payee, AMOUNT, deadline, payee, INVOICE_REF);
    }

    // -------------------------------------------------------------------------
    // Release
    // -------------------------------------------------------------------------

    function test_PayerCanRelease() public {
        uint256 id = _open();

        vm.expectEmit(true, true, false, true, address(escrow));
        emit EscrowReleased(id, payee, AMOUNT, payer);

        vm.prank(payer);
        escrow.release(id);

        assertEq(usdc.balanceOf(payee), AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0, "custody fully discharged");
        assertEq(uint8(escrow.getEscrow(id).status), uint8(PaymentEscrow.Status.Released));
    }

    function test_ArbiterCanRelease() public {
        uint256 id = _open();

        vm.prank(arbiter);
        escrow.release(id);
        assertEq(usdc.balanceOf(payee), AMOUNT);
    }

    function test_PayeeCannotRelease() public {
        uint256 id = _open();

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.NotAuthorizedToRelease.selector, id, payee));
        escrow.release(id);
    }

    function test_StrangerCannotRelease() public {
        uint256 id = _open();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.NotAuthorizedToRelease.selector, id, stranger));
        escrow.release(id);
    }

    function test_ReleaseAfterDeadlineStillAllowed() public {
        // The deadline is the payer's backstop, not a cutoff on their own
        // ability to pay a late-but-accepted delivery.
        uint256 id = _open();
        vm.warp(deadline + 30 days);

        vm.prank(payer);
        escrow.release(id);
        assertEq(usdc.balanceOf(payee), AMOUNT);
    }

    function test_CannotReleaseTwice() public {
        uint256 id = _open();

        vm.prank(payer);
        escrow.release(id);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(PaymentEscrow.EscrowNotFunded.selector, id, PaymentEscrow.Status.Released)
        );
        escrow.release(id);
    }

    // -------------------------------------------------------------------------
    // Refund
    // -------------------------------------------------------------------------

    function test_PayeeCanRefund() public {
        uint256 id = _open();

        vm.expectEmit(true, true, false, true, address(escrow));
        emit EscrowRefunded(id, payer, AMOUNT, payee);

        vm.prank(payee);
        escrow.refund(id);

        assertEq(usdc.balanceOf(payer), 1_000_000e6, "payer made whole");
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint8(escrow.getEscrow(id).status), uint8(PaymentEscrow.Status.Refunded));
    }

    function test_ArbiterCanRefund() public {
        uint256 id = _open();

        vm.prank(arbiter);
        escrow.refund(id);
        assertEq(usdc.balanceOf(payer), 1_000_000e6);
    }

    function test_PayerCannotRefundDirectly() public {
        // The payer's route out is claimExpired, after the deadline.
        uint256 id = _open();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.NotAuthorizedToRefund.selector, id, payer));
        escrow.refund(id);
    }

    function test_CannotRefundAfterRelease() public {
        uint256 id = _open();

        vm.prank(payer);
        escrow.release(id);

        vm.prank(payee);
        vm.expectRevert(
            abi.encodeWithSelector(PaymentEscrow.EscrowNotFunded.selector, id, PaymentEscrow.Status.Released)
        );
        escrow.refund(id);
    }

    // -------------------------------------------------------------------------
    // Expiry
    // -------------------------------------------------------------------------

    function test_PayerCanClaimAfterDeadline() public {
        uint256 id = _open();
        vm.warp(deadline + 1);

        assertTrue(escrow.isExpired(id));

        vm.prank(payer);
        escrow.claimExpired(id);

        assertEq(usdc.balanceOf(payer), 1_000_000e6);
        assertEq(uint8(escrow.getEscrow(id).status), uint8(PaymentEscrow.Status.Refunded));
    }

    function test_ClaimRevertsBeforeDeadline() public {
        uint256 id = _open();

        assertFalse(escrow.isExpired(id));

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(PaymentEscrow.DeadlineNotReached.selector, id, deadline, block.timestamp)
        );
        escrow.claimExpired(id);
    }

    function test_ClaimRevertsExactlyAtDeadline() public {
        uint256 id = _open();
        vm.warp(deadline);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(PaymentEscrow.DeadlineNotReached.selector, id, deadline, deadline)
        );
        escrow.claimExpired(id);
    }

    function test_OnlyPayerCanClaimExpired() public {
        uint256 id = _open();
        vm.warp(deadline + 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.NotPayer.selector, id, stranger));
        escrow.claimExpired(id);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.NotPayer.selector, id, payee));
        escrow.claimExpired(id);
    }

    function test_ReleasedEscrowIsNotExpired() public {
        uint256 id = _open();

        vm.prank(payer);
        escrow.release(id);

        vm.warp(deadline + 365 days);
        assertFalse(escrow.isExpired(id));
    }

    // -------------------------------------------------------------------------
    // Unknown escrows
    // -------------------------------------------------------------------------

    function test_UnknownEscrowReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.EscrowNotFound.selector, 999));
        escrow.getEscrow(999);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(PaymentEscrow.EscrowNotFound.selector, 999));
        escrow.release(999);
    }

    function test_IsExpiredIsFalseForUnknownEscrow() public view {
        assertFalse(escrow.isExpired(999));
    }

    // -------------------------------------------------------------------------
    // Pause semantics
    // -------------------------------------------------------------------------

    function test_PauseBlocksOpening() public {
        vm.prank(owner);
        escrow.pause();

        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.openEscrow(payee, AMOUNT, deadline, arbiter, INVOICE_REF);
    }

    function test_PauseDoesNotStrandFunds() public {
        // The core custody guarantee: a pause must never lock money in.
        uint256 released = _open();
        uint256 refunded = _open();
        uint256 expired = _open();

        vm.prank(owner);
        escrow.pause();

        vm.prank(payer);
        escrow.release(released);
        assertEq(usdc.balanceOf(payee), AMOUNT, "release works while paused");

        vm.prank(payee);
        escrow.refund(refunded);

        vm.warp(deadline + 1);
        vm.prank(payer);
        escrow.claimExpired(expired);

        assertEq(usdc.balanceOf(address(escrow)), 0, "no funds stranded by pause");
    }

    function test_OnlyOwnerCanPause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.pause();
    }

    // -------------------------------------------------------------------------
    // Fuzz / invariant-ish
    // -------------------------------------------------------------------------

    function testFuzz_CustodyIsFullyDischarged(uint96 amount, uint8 route) public {
        amount = uint96(bound(amount, 1, 500_000e6));
        route = uint8(bound(route, 0, 2));

        vm.prank(payer);
        uint256 id = escrow.openEscrow(payee, amount, deadline, arbiter, INVOICE_REF);
        assertEq(usdc.balanceOf(address(escrow)), amount);

        if (route == 0) {
            vm.prank(payer);
            escrow.release(id);
            assertEq(usdc.balanceOf(payee), amount);
        } else if (route == 1) {
            vm.prank(payee);
            escrow.refund(id);
            assertEq(usdc.balanceOf(payer), 1_000_000e6);
        } else {
            vm.warp(deadline + 1);
            vm.prank(payer);
            escrow.claimExpired(id);
            assertEq(usdc.balanceOf(payer), 1_000_000e6);
        }

        // Whichever path settled it, the contract holds nothing afterwards.
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testFuzz_DeadlineBoundary(uint40 lifetime, uint40 elapsed) public {
        lifetime = uint40(bound(lifetime, 1, 3650 days));
        elapsed = uint40(bound(elapsed, 0, 3650 days));

        uint40 escrowDeadline = uint40(block.timestamp) + lifetime;

        vm.prank(payer);
        uint256 id = escrow.openEscrow(payee, AMOUNT, escrowDeadline, arbiter, INVOICE_REF);

        vm.warp(block.timestamp + elapsed);
        assertEq(escrow.isExpired(id), block.timestamp > escrowDeadline);
    }
}
