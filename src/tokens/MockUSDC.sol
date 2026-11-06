// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockUSDC
/// @notice TEST TOKEN ONLY. Not USDC, not a stablecoin, no reserves, no value. For local/testnet demos.
/// @dev 6 decimals like real USDC. `faucet()` hands out 10,000 tUSDC at most once per hour per address.
contract MockUSDC is ERC20, Ownable {
    uint256 public constant FAUCET_AMOUNT = 10_000e6;
    uint256 public constant FAUCET_COOLDOWN = 1 hours;

    /// @notice unix seconds of each address's last faucet claim (0 = never)
    mapping(address => uint256) public lastFaucet;

    event Faucet(address indexed to, uint256 amount);

    error FaucetCooldown(uint256 nextClaimAt);

    constructor(address owner_) ERC20("Test USDC", "tUSDC") Ownable(owner_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice owner-only free mint (test funding)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice 10,000 tUSDC to the caller, at most once per hour per address
    function faucet() external {
        uint256 last = lastFaucet[msg.sender];
        if (last != 0 && block.timestamp < last + FAUCET_COOLDOWN) revert FaucetCooldown(last + FAUCET_COOLDOWN);
        lastFaucet[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit Faucet(msg.sender, FAUCET_AMOUNT);
    }
}
