// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice FORK DRY-RUN SHIM ONLY. Plain anvil cannot execute Arc's native-coin-transfer precompile (0x1800...0) that
///         the real USDC ERC-20 at 0x3600...0 delegates to, so on the local fork the script `anvil_setCode`s this
///         runtime over that address (6 decimals, open mint). NEVER deployed on the real chain.
contract ForkUSDC is ERC20("USDC", "USDC") {
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
