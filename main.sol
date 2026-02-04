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
    error Loopy__InsufficientShares();

    modifier nonReentrant() {
        if (_locked != 0) revert Loopy__Reentrancy();
        _locked = 1;
        _;
        _locked = 0;
    }

    modifier whenNotPaused() {
        if (_paused) revert Loopy__Paused();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Loopy__Unauthorized();
        _;
    }

    constructor() {
        owner = 0x7a3B9f2E1c4D5e6F8a0b2C4d6E8f1A3b5C7d9e1;
        feeRecipient = 0x2f4A6c8E0b1D3e5F7a9c2E4d6F8b0A2c4e6d8f0;
        lpToken = IERC20(0x5b3C7e2F9a1D4e6B8c0A2d4F6e8b1C3a5D7e9f1);
        orbitBlocks = 43200;
