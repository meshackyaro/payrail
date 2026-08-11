// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchPayout} from "../src/BatchPayout.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {InvoiceRegistry} from "../src/InvoiceRegistry.sol";
import {PaymentEscrow} from "../src/PaymentEscrow.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @title Deploy
/// @notice Deploys the PayRail contract suite against an Arc network.
///
/// @dev Usage:
///
///      Local (anvil):
///        anvil
///        forge script script/Deploy.s.sol:Deploy --rpc-url local --broadcast
///
///      Arc testnet (keystore account -- preferred):
///        cast wallet import payrail-deployer --interactive
///        forge script script/Deploy.s.sol:Deploy \
///          --rpc-url arc_testnet --account payrail-deployer --broadcast
///
///      Arc testnet (raw key -- throwaway keys only):
///        forge script script/Deploy.s.sol:Deploy \
///          --rpc-url arc_testnet --private-key $PRIVATE_KEY --broadcast
///
///      Required env: USDC_ADDRESS. Optional: PAYRAIL_TREASURY,
///      PAYRAIL_COMPLIANCE_OFFICER (both default to the deployer).
///
///      Note that ARC_TESTNET_RPC_URL must be set for the `arc_testnet` alias to
///      resolve -- see .env.example. Arc's chain ID is not hardcoded anywhere in
///      this repo; take it from Circle's docs and confirm the RPC points where
///      you expect before broadcasting.
contract Deploy is Script {
    struct Deployment {
        ComplianceRegistry compliance;
        InvoiceRegistry invoices;
        BatchPayout payouts;
        PaymentEscrow escrow;
    }

    error UsdcAddressNotSet();
    error UsdcAddressHasNoCode(address usdc);

    function run() external returns (Deployment memory deployment) {
        address usdc = vm.envOr("USDC_ADDRESS", address(0));
        if (usdc == address(0)) revert UsdcAddressNotSet();

        address deployer = msg.sender;
        address treasury = vm.envOr("PAYRAIL_TREASURY", deployer);
        address officer = vm.envOr("PAYRAIL_COMPLIANCE_OFFICER", treasury);

        // Catches the most common deploy mistake: a USDC address copied from the
        // wrong network. Skipped on a dry run, where state may not be loaded.
        if (usdc.code.length == 0) revert UsdcAddressHasNoCode(usdc);

        console.log("PayRail deployment");
        console.log("  deployer:  %s", deployer);
        console.log("  chain id:  %s", block.chainid);
        console.log("  USDC:      %s", usdc);
        console.log("  treasury:  %s", treasury);
        console.log("  officer:   %s", officer);

        vm.startBroadcast();

        deployment.compliance = new ComplianceRegistry(treasury, officer);
        deployment.invoices = new InvoiceRegistry(usdc, address(deployment.compliance), treasury);
        deployment.payouts = new BatchPayout(usdc, address(deployment.compliance), treasury);
        deployment.escrow = new PaymentEscrow(usdc, treasury);

        vm.stopBroadcast();

        console.log("Deployed:");
        console.log("  ComplianceRegistry: %s", address(deployment.compliance));
        console.log("  InvoiceRegistry:    %s", address(deployment.invoices));
        console.log("  BatchPayout:        %s", address(deployment.payouts));
        console.log("  PaymentEscrow:      %s", address(deployment.escrow));

        if (treasury == deployer) {
            console.log("");
            console.log("WARNING: treasury == deployer EOA. Transfer ownership to a");
            console.log("multisig before this handles real money. Ownable2Step means");
            console.log("the new owner must call acceptOwnership().");
        }
    }
}
