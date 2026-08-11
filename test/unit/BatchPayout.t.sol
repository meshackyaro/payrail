// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchPayout} from "../../src/BatchPayout.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {IERC20Errors} from "openzeppelin-contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";

contract BatchPayoutTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    BatchPayout internal payout;

    address internal owner = makeAddr("owner");
    address internal officer = makeAddr("officer");
    address internal payer = makeAddr("payer");
    address internal stranger = makeAddr("stranger");

    address internal vendorA = makeAddr("vendorA");
    address internal vendorB = makeAddr("vendorB");
    address internal vendorC = makeAddr("vendorC");

    bytes32 internal constant BATCH_REF = keccak256("PAYROLL-2026-08");

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

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(owner, officer);
        payout = new BatchPayout(address(usdc), address(compliance), owner);

        usdc.mint(payer, 1_000_000e6);

        vm.prank(payer);
        usdc.approve(address(payout), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _threePayments() internal view returns (BatchPayout.Payment[] memory payments) {
        payments = new BatchPayout.Payment[](3);
        payments[0] = BatchPayout.Payment(vendorA, 1000e6, keccak256("INV-A"));
        payments[1] = BatchPayout.Payment(vendorB, 2500e6, keccak256("INV-B"));
        payments[2] = BatchPayout.Payment(vendorC, 400e6, keccak256("INV-C"));
    }

    function _verify(address account) internal {
        vm.prank(officer);
        compliance.setKycStatus(account, IComplianceRegistry.KycStatus.Verified, 0, keccak256("ok"));
    }

    // -------------------------------------------------------------------------
    // Happy path
    // -------------------------------------------------------------------------

    function test_ExecuteBatchPaysEveryRecipient() public {
        BatchPayout.Payment[] memory payments = _threePayments();

        vm.prank(payer);
        (uint256 batchId, uint256 total) = payout.executeBatch(payments, false, BATCH_REF);

        assertEq(batchId, 1);
        assertEq(total, 3900e6);
        assertEq(usdc.balanceOf(vendorA), 1000e6);
        assertEq(usdc.balanceOf(vendorB), 2500e6);
        assertEq(usdc.balanceOf(vendorC), 400e6);
        assertEq(usdc.balanceOf(payer), 1_000_000e6 - 3900e6);
    }

    function test_NoCustodyHeldByContract() public {
        BatchPayout.Payment[] memory payments = _threePayments();

        vm.prank(payer);
        payout.executeBatch(payments, false, BATCH_REF);

        assertEq(usdc.balanceOf(address(payout)), 0, "contract must never hold funds");
    }

    function test_EmitsPerPaymentAndBatchEvents() public {
        BatchPayout.Payment[] memory payments = _threePayments();

        vm.expectEmit(true, true, true, true, address(payout));
        emit PayoutSent(1, vendorA, 1000e6, keccak256("INV-A"));
        vm.expectEmit(true, true, true, true, address(payout));
        emit PayoutSent(1, vendorB, 2500e6, keccak256("INV-B"));
        vm.expectEmit(true, true, true, true, address(payout));
        emit PayoutSent(1, vendorC, 400e6, keccak256("INV-C"));
        vm.expectEmit(true, true, false, true, address(payout));
        emit BatchExecuted(1, payer, 3900e6, 3, false, BATCH_REF);

        vm.prank(payer);
        payout.executeBatch(payments, false, BATCH_REF);
    }

    function test_BatchIdsIncrement() public {
        BatchPayout.Payment[] memory payments = _threePayments();

        vm.startPrank(payer);
        (uint256 first,) = payout.executeBatch(payments, false, BATCH_REF);
        (uint256 second,) = payout.executeBatch(payments, false, BATCH_REF);
        vm.stopPrank();

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(payout.nextBatchId(), 3);
    }

    function test_DuplicateRecipientsAreAllowed() public {
        // Two invoices to the same vendor in one run is ordinary.
        BatchPayout.Payment[] memory payments = new BatchPayout.Payment[](2);
        payments[0] = BatchPayout.Payment(vendorA, 100e6, keccak256("INV-1"));
        payments[1] = BatchPayout.Payment(vendorA, 250e6, keccak256("INV-2"));

        vm.prank(payer);
        (, uint256 total) = payout.executeBatch(payments, false, BATCH_REF);

        assertEq(total, 350e6);
        assertEq(usdc.balanceOf(vendorA), 350e6);
    }

    function test_SinglePaymentBatch() public {
        BatchPayout.Payment[] memory payments = new BatchPayout.Payment[](1);
        payments[0] = BatchPayout.Payment(vendorA, 42e6, bytes32(0));

        vm.prank(payer);
        (, uint256 total) = payout.executeBatch(payments, false, BATCH_REF);
        assertEq(total, 42e6);
    }

    function test_MaxBatchSizeIsAccepted() public {
        uint256 size = payout.MAX_BATCH_SIZE();
        BatchPayout.Payment[] memory payments = new BatchPayout.Payment[](size);
        for (uint256 i; i < size; ++i) {
            payments[i] = BatchPayout.Payment(address(uint160(1000 + i)), 1e6, bytes32(i));
        }

        vm.prank(payer);
        (, uint256 total) = payout.executeBatch(payments, false, BATCH_REF);
        assertEq(total, size * 1e6);
    }

    // -------------------------------------------------------------------------
    // Validation
    // -------------------------------------------------------------------------

    function test_RevertsOnEmptyBatch() public {
        BatchPayout.Payment[] memory payments = new BatchPayout.Payment[](0);

        vm.prank(payer);
        vm.expectRevert(BatchPayout.EmptyBatch.selector);
        payout.executeBatch(payments, false, BATCH_REF);
    }

    function test_RevertsWhenBatchTooLarge() public {
        uint256 size = payout.MAX_BATCH_SIZE() + 1;
        BatchPayout.Payment[] memory payments = new BatchPayout.Payment[](size);
        for (uint256 i; i < size; ++i) {
            payments[i] = BatchPayout.Payment(address(uint160(1000 + i)), 1e6, bytes32(0));
        }

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(BatchPayout.BatchTooLarge.selector, size, payout.MAX_BATCH_SIZE())
        );
        payout.executeBatch(payments, false, BATCH_REF);
    }

    function test_RevertsOnZeroRecipient() public {
        BatchPayout.Payment[] memory payments = _threePayments();
        payments[1].recipient = address(0);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BatchPayout.InvalidRecipient.selector, 1));
        payout.executeBatch(payments, false, BATCH_REF);
    }

    function test_RevertsWhenPayingSelf() public {
        BatchPayout.Payment[] memory payments = _threePayments();
        payments[2].recipient = payer;

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BatchPayout.InvalidRecipient.selector, 2));
        payout.executeBatch(payments, false, BATCH_REF);
    }

    function test_RevertsOnZeroAmount() public {
        BatchPayout.Payment[] memory payments = _threePayments();
        payments[0].amount = 0;

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BatchPayout.ZeroAmount.selector, 0));
        payout.executeBatch(payments, false, BATCH_REF);
    }

    // -------------------------------------------------------------------------
    // Atomicity
    // -------------------------------------------------------------------------

    function test_BatchIsAtomicOnInsufficientBalance() public {
        // Drain the payer so the second transfer cannot succeed. Read the
        // balance before pranking -- an external call in the argument would
        // consume the prank and send from this test contract instead.
        uint256 drain = usdc.balanceOf(payer) - 1500e6;
        vm.prank(payer);
        usdc.transfer(stranger, drain);

        BatchPayout.Payment[] memory payments = _threePayments(); // needs 3,900

        vm.prank(payer);
        vm.expectRevert();
        payout.executeBatch(payments, false, BATCH_REF);

        // Nothing settled -- not even the first payment, which would have fit.
        assertEq(usdc.balanceOf(vendorA), 0, "first payment must roll back too");
        assertEq(usdc.balanceOf(vendorB), 0);
        assertEq(usdc.balanceOf(vendorC), 0);
        assertEq(usdc.balanceOf(payer), 1500e6, "payer balance untouched");
    }

    function test_BatchIsAtomicOnInsufficientAllowance() public {
        vm.prank(payer);
        usdc.approve(address(payout), 2000e6); // less than the 3,900 total

        BatchPayout.Payment[] memory payments = _threePayments();

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(payout), 1000e6, 2500e6
            )
        );
        payout.executeBatch(payments, false, BATCH_REF);

        assertEq(usdc.balanceOf(vendorA), 0);
        assertEq(usdc.balanceOf(vendorB), 0);
    }

    function test_FailedBatchDoesNotConsumeBatchId() public {
        BatchPayout.Payment[] memory bad = new BatchPayout.Payment[](0);

        vm.prank(payer);
        vm.expectRevert(BatchPayout.EmptyBatch.selector);
        payout.executeBatch(bad, false, BATCH_REF);

        // The whole call reverted, so the id counter is untouched.
        assertEq(payout.nextBatchId(), 1);
    }

    // -------------------------------------------------------------------------
    // KYC gating
    // -------------------------------------------------------------------------

    function test_VerifiedBatchRejectsUnverifiedRecipient() public {
        BatchPayout.Payment[] memory payments = _threePayments();
        _verify(vendorA);
        _verify(vendorB);
        // vendorC is deliberately left unverified.

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BatchPayout.RecipientNotVerified.selector, 2, vendorC));
        payout.executeBatch(payments, true, BATCH_REF);

        assertEq(usdc.balanceOf(vendorA), 0, "atomic: verified recipients unpaid too");
    }

    function test_VerifiedBatchSucceedsWhenAllVerified() public {
        BatchPayout.Payment[] memory payments = _threePayments();
        _verify(vendorA);
        _verify(vendorB);
        _verify(vendorC);

        vm.prank(payer);
        (, uint256 total) = payout.executeBatch(payments, true, BATCH_REF);

        assertEq(total, 3900e6);
        assertEq(usdc.balanceOf(vendorC), 400e6);
    }

    function test_UnverifiedRecipientsFineWhenGateIsOff() public {
        BatchPayout.Payment[] memory payments = _threePayments();

        vm.prank(payer);
        payout.executeBatch(payments, false, BATCH_REF);
        assertEq(usdc.balanceOf(vendorC), 400e6);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function test_PreviewTotal() public view {
        assertEq(payout.previewTotal(_threePayments()), 3900e6);
    }

    function test_PreviewTotalOfEmptyBatch() public view {
        assertEq(payout.previewTotal(new BatchPayout.Payment[](0)), 0);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function test_PauseBlocksExecution() public {
        vm.prank(owner);
        payout.pause();

        BatchPayout.Payment[] memory payments = _threePayments();
        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        payout.executeBatch(payments, false, BATCH_REF);
    }

    function test_UnpauseRestoresExecution() public {
        vm.startPrank(owner);
        payout.pause();
        payout.unpause();
        vm.stopPrank();

        BatchPayout.Payment[] memory payments = _threePayments();
        vm.prank(payer);
        (, uint256 total) = payout.executeBatch(payments, false, BATCH_REF);
        assertEq(total, 3900e6);
    }

    function test_OnlyOwnerCanPause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        payout.pause();
    }

    function test_SetComplianceRegistry() public {
        ComplianceRegistry next = new ComplianceRegistry(owner, officer);

        vm.prank(owner);
        payout.setComplianceRegistry(address(next));
        assertEq(address(payout.complianceRegistry()), address(next));
    }

    // -------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------

    function testFuzz_TotalMatchesPreviewAndBalances(uint96 a, uint96 b, uint96 c) public {
        a = uint96(bound(a, 1, 100_000e6));
        b = uint96(bound(b, 1, 100_000e6));
        c = uint96(bound(c, 1, 100_000e6));

        BatchPayout.Payment[] memory payments = new BatchPayout.Payment[](3);
        payments[0] = BatchPayout.Payment(vendorA, a, bytes32(0));
        payments[1] = BatchPayout.Payment(vendorB, b, bytes32(0));
        payments[2] = BatchPayout.Payment(vendorC, c, bytes32(0));

        uint256 preview = payout.previewTotal(payments);

        vm.prank(payer);
        (, uint256 total) = payout.executeBatch(payments, false, BATCH_REF);

        assertEq(total, preview, "preview must match what settles");
        assertEq(total, uint256(a) + b + c);
        assertEq(usdc.balanceOf(vendorA), a);
        assertEq(usdc.balanceOf(vendorB), b);
        assertEq(usdc.balanceOf(vendorC), c);
    }

    function testFuzz_BatchSizeWithinCap(uint8 size) public {
        vm.assume(size > 0);

        BatchPayout.Payment[] memory payments = new BatchPayout.Payment[](size);
        for (uint256 i; i < size; ++i) {
            payments[i] = BatchPayout.Payment(address(uint160(2000 + i)), 1e6, bytes32(i));
        }

        vm.prank(payer);
        (, uint256 total) = payout.executeBatch(payments, false, BATCH_REF);
        assertEq(total, uint256(size) * 1e6);
    }
}
