// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title StockToken
/// @notice TEST TOKEN ONLY. Represents nothing: no real shares, no custody, not a security.
///         Stands in for an issuer's tokenized stock (for example an Ondo-style token) in demos.
/// @dev 18 decimals. Only the immutable `issuer` (a StockIssuer) can mint or burn.
///      `burn` takes tokens straight from `from` without an allowance because the issuer is trusted
///      to burn only the caller's own tokens in `redeem`.
contract StockToken is ERC20 {
    address public immutable issuer;

    error NotIssuer();

    modifier onlyIssuer() {
        if (msg.sender != issuer) revert NotIssuer();
        _;
    }

    constructor(string memory name_, string memory symbol_, address issuer_) ERC20(name_, symbol_) {
        issuer = issuer_;
    }

    function mint(address to, uint256 amount) external onlyIssuer {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyIssuer {
        _burn(from, amount);
    }
}
