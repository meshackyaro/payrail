// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @notice Minimal 6-decimal stand-in for USDC in tests.
/// @dev Mirrors the decimals of real USDC so that amount arithmetic in tests
///      matches production. Freely mintable -- test-only, never deployed.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
