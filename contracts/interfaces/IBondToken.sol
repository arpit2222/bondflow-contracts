// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IBondToken
 * @dev Interface for Bond token with mint and burn capabilities
 */
interface IBondToken is IERC20 {
    /**
     * @dev Mint tokens for address
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @dev Burn tokens from caller
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external;
}
