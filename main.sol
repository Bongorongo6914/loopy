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

    struct RingConfig {
        uint256 weightBps;
        uint256 feeBps;
        uint256 minLockBlocks;
        uint256 orbitMultiplier;
    }

    struct RingState {
        uint256 totalDeposited;
        uint256 totalShares;
        uint256 accumulatedYieldPerShare;
        uint256 lastOrbitBlock;
    }

    struct Position {
        uint256 shares;
        uint256 depositBlock;
        uint256 rewardDebt;
    }

    address public immutable owner;
    address public immutable feeRecipient;
    IERC20 public immutable lpToken;
    uint256 public immutable orbitBlocks;
    uint256 public immutable maxDepositPerRing;

    RingConfig[RING_COUNT] private _ringConfigs;
    RingState[RING_COUNT] private _ringStates;
    mapping(uint256 => mapping(address => Position)) private _positions;

    uint256 private _locked;
    bool private _paused;

    event Deposit(address indexed user, uint256 ringIndex, uint256 assets, uint256 shares);
    event Withdraw(address indexed user, uint256 ringIndex, uint256 assets, uint256 shares);
    event Orbit(uint256 ringIndex, uint256 yieldAmount, uint256 feeTaken);
    event RingMigrate(address indexed user, uint256 fromRing, uint256 toRing, uint256 shares);
    event PauseToggled(bool paused);
    event FeeSweep(address token, uint256 amount);

    error Loopy__ZeroAmount();
    error Loopy__InvalidRing();
    error Loopy__Locked();
    error Loopy__Paused();
    error Loopy__Reentrancy();
    error Loopy__Unauthorized();
    error Loopy__ExceedsMaxDeposit();
