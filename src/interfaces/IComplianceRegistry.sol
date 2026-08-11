// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IComplianceRegistry
/// @notice Read interface for counterparty KYC attestations, consumed by the
///         payment contracts when an invoice or payout requires a verified
///         counterparty.
interface IComplianceRegistry {
    /// @notice Lifecycle of a counterparty's KYC standing.
    /// @dev `Unverified` is the zero value, so an address that has never been
    ///      attested reads as `Unverified` rather than reverting.
    enum KycStatus {
        Unverified,
        Verified,
        Rejected,
        Suspended
    }

    /// @param status      Current standing of the counterparty.
    /// @param verifiedAt  When the attestation was last written.
    /// @param expiresAt   Expiry timestamp; `0` means the attestation does not expire.
    /// @param evidenceRef Hash or pointer to off-chain KYC evidence. Never store PII on-chain.
    struct Attestation {
        KycStatus status;
        uint40 verifiedAt;
        uint40 expiresAt;
        bytes32 evidenceRef;
    }

    /// @notice Returns the full attestation record for `account`.
    function attestationOf(address account) external view returns (Attestation memory);

    /// @notice True only when `account` is `Verified` and the attestation has not expired.
    function isVerified(address account) external view returns (bool);
}
