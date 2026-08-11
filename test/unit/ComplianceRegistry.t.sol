// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/access/IAccessControl.sol";

contract ComplianceRegistryTest is Test {
    ComplianceRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal officer = makeAddr("officer");
    address internal stranger = makeAddr("stranger");
    address internal vendor = makeAddr("vendor");

    bytes32 internal constant EVIDENCE = keccak256("kyc-packet-v1");

    function setUp() public {
        // Move off timestamp 0 so that expiry comparisons are meaningful.
        vm.warp(1_700_000_000);
        registry = new ComplianceRegistry(admin, officer);
    }

    function test_ConstructorGrantsRoles() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.COMPLIANCE_OFFICER_ROLE(), officer));
    }

    function test_ConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        new ComplianceRegistry(address(0), officer);

        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        new ComplianceRegistry(admin, address(0));
    }

    function test_UnverifiedByDefault() public view {
        assertFalse(registry.isVerified(vendor));
        assertEq(
            uint8(registry.attestationOf(vendor).status), uint8(IComplianceRegistry.KycStatus.Unverified)
        );
    }

    function test_OfficerCanVerify() public {
        vm.prank(officer);
        registry.setKycStatus(vendor, IComplianceRegistry.KycStatus.Verified, 0, EVIDENCE);

        assertTrue(registry.isVerified(vendor));

        IComplianceRegistry.Attestation memory a = registry.attestationOf(vendor);
        assertEq(uint8(a.status), uint8(IComplianceRegistry.KycStatus.Verified));
        assertEq(a.verifiedAt, uint40(block.timestamp));
        assertEq(a.expiresAt, 0);
        assertEq(a.evidenceRef, EVIDENCE);
    }

    function test_NonOfficerCannotVerify() public {
        // Cache the role first: a getter call inside the expectRevert argument
        // would consume the prank, and the real call would come from this test
        // contract instead of `stranger`.
        bytes32 officerRole = registry.COMPLIANCE_OFFICER_ROLE();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, officerRole
            )
        );
        registry.setKycStatus(vendor, IComplianceRegistry.KycStatus.Verified, 0, EVIDENCE);
    }

    function test_AttestationExpires() public {
        uint40 expiry = uint40(block.timestamp + 30 days);

        vm.prank(officer);
        registry.setKycStatus(vendor, IComplianceRegistry.KycStatus.Verified, expiry, EVIDENCE);
        assertTrue(registry.isVerified(vendor));

        // Still valid one second before expiry.
        vm.warp(expiry - 1);
        assertTrue(registry.isVerified(vendor));

        // Expiry is exclusive: at exactly expiresAt the attestation is stale.
        vm.warp(expiry);
        assertFalse(registry.isVerified(vendor));
    }

    function test_CannotSetExpiryInPast() public {
        uint40 stale = uint40(block.timestamp - 1);

        vm.prank(officer);
        vm.expectRevert(
            abi.encodeWithSelector(ComplianceRegistry.ExpiryNotInFuture.selector, stale, block.timestamp)
        );
        registry.setKycStatus(vendor, IComplianceRegistry.KycStatus.Verified, stale, EVIDENCE);
    }

    function test_SuspensionRevokesVerification() public {
        vm.startPrank(officer);
        registry.setKycStatus(vendor, IComplianceRegistry.KycStatus.Verified, 0, EVIDENCE);
        assertTrue(registry.isVerified(vendor));

        registry.setKycStatus(vendor, IComplianceRegistry.KycStatus.Suspended, 0, EVIDENCE);
        vm.stopPrank();

        assertFalse(registry.isVerified(vendor));
    }

    function test_CannotAttestZeroAddress() public {
        vm.prank(officer);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        registry.setKycStatus(address(0), IComplianceRegistry.KycStatus.Verified, 0, EVIDENCE);
    }

    function test_AdminCanGrantOfficerRole() public {
        address newOfficer = makeAddr("newOfficer");
        bytes32 officerRole = registry.COMPLIANCE_OFFICER_ROLE();

        vm.prank(admin);
        registry.grantRole(officerRole, newOfficer);

        vm.prank(newOfficer);
        registry.setKycStatus(vendor, IComplianceRegistry.KycStatus.Verified, 0, EVIDENCE);
        assertTrue(registry.isVerified(vendor));
    }

    function testFuzz_VerificationHoldsUntilExpiry(uint40 lifetime, uint40 elapsed) public {
        lifetime = uint40(bound(lifetime, 1, 3650 days));
        elapsed = uint40(bound(elapsed, 0, 3650 days));

        uint40 expiry = uint40(block.timestamp) + lifetime;
        vm.prank(officer);
        registry.setKycStatus(vendor, IComplianceRegistry.KycStatus.Verified, expiry, EVIDENCE);

        vm.warp(block.timestamp + elapsed);
        assertEq(registry.isVerified(vendor), block.timestamp < expiry);
    }
}
