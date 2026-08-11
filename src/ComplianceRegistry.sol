// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

/// @title ComplianceRegistry
/// @notice Records counterparty KYC standing for PayRail's payment contracts.
/// @dev Holds references to off-chain evidence only. Nothing here should ever
///      contain personally identifying information: `evidenceRef` is a hash or
///      an opaque pointer into the compliance system of record.
///
///      Attestations can expire. Consumers should call {isVerified}, which
///      folds expiry into the answer, rather than reading {attestationOf} and
///      comparing the status enum themselves.
contract ComplianceRegistry is AccessControl, IComplianceRegistry {
    /// @notice Role permitted to write attestations.
    bytes32 public constant COMPLIANCE_OFFICER_ROLE = keccak256("COMPLIANCE_OFFICER_ROLE");

    mapping(address account => Attestation) private _attestations;

    /// @notice Emitted whenever an attestation is written or overwritten.
    event KycStatusSet(
        address indexed account,
        KycStatus indexed status,
        uint40 expiresAt,
        bytes32 evidenceRef,
        address indexed officer
    );

    error ZeroAddress();
    error ExpiryNotInFuture(uint40 expiresAt, uint256 currentTime);

    /// @param admin   Receives `DEFAULT_ADMIN_ROLE`; should be a multisig in production.
    /// @param officer Receives `COMPLIANCE_OFFICER_ROLE`.
    constructor(address admin, address officer) {
        if (admin == address(0) || officer == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_OFFICER_ROLE, officer);
    }

    /// @notice Write the KYC standing for `account`.
    /// @param expiresAt Expiry timestamp, or `0` for an attestation that never expires.
    ///                  Must be in the future when non-zero, so that a fresh
    ///                  attestation cannot be written already-expired.
    function setKycStatus(address account, KycStatus status, uint40 expiresAt, bytes32 evidenceRef)
        external
        onlyRole(COMPLIANCE_OFFICER_ROLE)
    {
        if (account == address(0)) revert ZeroAddress();
        if (expiresAt != 0 && expiresAt <= block.timestamp) {
            revert ExpiryNotInFuture(expiresAt, block.timestamp);
        }

        _attestations[account] = Attestation({
            status: status,
            verifiedAt: uint40(block.timestamp),
            expiresAt: expiresAt,
            evidenceRef: evidenceRef
        });

        emit KycStatusSet(account, status, expiresAt, evidenceRef, msg.sender);
    }

    /// @inheritdoc IComplianceRegistry
    function attestationOf(address account) external view returns (Attestation memory) {
        return _attestations[account];
    }

    /// @inheritdoc IComplianceRegistry
    function isVerified(address account) public view returns (bool) {
        Attestation storage a = _attestations[account];
        if (a.status != KycStatus.Verified) return false;
        return a.expiresAt == 0 || a.expiresAt > block.timestamp;
    }
}
