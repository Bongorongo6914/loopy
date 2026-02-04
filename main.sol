// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Loopy
 * @notice Concentric ring liquidity primitive. LPs allocate to rings; yield orbits
 *         inward and is amplified by ring depth. Built for the Meridian Series
 *         deployment on mainnet — do not use on testnets without forking config.
 */

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract Loopy {
    uint256 public constant RING_COUNT = 5;
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MIN_DEPOSIT = 1e15;
    uint256 public constant MAX_RING_WEIGHT = 1e18;
