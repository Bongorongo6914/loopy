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
        maxDepositPerRing = 500_000 * 1e18;

        _ringConfigs[0] = RingConfig({
            weightBps: 3400,
            feeBps: 47,
            minLockBlocks: 14400,
            orbitMultiplier: 1e18
        });
        _ringConfigs[1] = RingConfig({
            weightBps: 2800,
            feeBps: 63,
            minLockBlocks: 28800,
            orbitMultiplier: 12e17
        });
        _ringConfigs[2] = RingConfig({
            weightBps: 2200,
            feeBps: 81,
            minLockBlocks: 43200,
            orbitMultiplier: 15e17
        });
        _ringConfigs[3] = RingConfig({
            weightBps: 1100,
            feeBps: 94,
            minLockBlocks: 57600,
            orbitMultiplier: 18e17
        });
        _ringConfigs[4] = RingConfig({
            weightBps: 500,
            feeBps: 112,
            minLockBlocks: 72000,
            orbitMultiplier: 22e17
        });
    }

    function deposit(uint256 ringIndex, uint256 assets) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (ringIndex >= RING_COUNT) revert Loopy__InvalidRing();
        if (assets < MIN_DEPOSIT) revert Loopy__ZeroAmount();

        RingState storage state = _ringStates[ringIndex];
        uint256 cap = maxDepositPerRing;
        if (state.totalDeposited + assets > cap) revert Loopy__ExceedsMaxDeposit();

        lpToken.transferFrom(msg.sender, address(this), assets);

        if (state.totalShares == 0) {
            shares = assets;
        } else {
            shares = (assets * state.totalShares) / state.totalDeposited;
        }

        Position storage pos = _positions[ringIndex][msg.sender];
        if (pos.shares > 0) {
            uint256 pending = (pos.shares * state.accumulatedYieldPerShare) / 1e18 - pos.rewardDebt;
            if (pending > 0) {
                pos.rewardDebt = (pos.shares * state.accumulatedYieldPerShare) / 1e18;
            }
        }

        state.totalDeposited += assets;
        state.totalShares += shares;
        pos.shares += shares;
        pos.depositBlock = block.number;
        pos.rewardDebt = (pos.shares * state.accumulatedYieldPerShare) / 1e18;

        emit Deposit(msg.sender, ringIndex, assets, shares);
        return shares;
    }

    function withdraw(uint256 ringIndex, uint256 shares) external nonReentrant returns (uint256 assets) {
        if (ringIndex >= RING_COUNT) revert Loopy__InvalidRing();

        Position storage pos = _positions[ringIndex][msg.sender];
        if (shares > pos.shares) revert Loopy__InsufficientShares();

        RingConfig memory cfg = _ringConfigs[ringIndex];
        if (block.number < pos.depositBlock + cfg.minLockBlocks) revert Loopy__Locked();

        RingState storage state = _ringStates[ringIndex];
        assets = state.totalDeposited == 0 ? 0 : (shares * state.totalDeposited) / state.totalShares;

        uint256 pending = (pos.shares * state.accumulatedYieldPerShare) / 1e18 - pos.rewardDebt;
        pos.rewardDebt = ((pos.shares - shares) * state.accumulatedYieldPerShare) / 1e18;
        pos.shares -= shares;

        state.totalShares -= shares;
        state.totalDeposited -= assets;

        if (pending > 0) {
            uint256 bal = lpToken.balanceOf(address(this));
            if (pending <= bal) {
                lpToken.transfer(msg.sender, pending);
            }
        }

        lpToken.transfer(msg.sender, assets);
        emit Withdraw(msg.sender, ringIndex, assets, shares);
        return assets;
    }

    function orbit(uint256 ringIndex, uint256 yieldAmount) external nonReentrant whenNotPaused {
        if (ringIndex >= RING_COUNT) revert Loopy__InvalidRing();
        if (yieldAmount == 0) revert Loopy__ZeroAmount();

        lpToken.transferFrom(msg.sender, address(this), yieldAmount);

        RingConfig memory cfg = _ringConfigs[ringIndex];
        uint256 fee = (yieldAmount * cfg.feeBps) / BPS_DENOM;
        uint256 netYield = yieldAmount - fee;

        if (fee > 0) {
            lpToken.transfer(feeRecipient, fee);
        }

        RingState storage state = _ringStates[ringIndex];
        if (state.totalShares > 0) {
            uint256 accDelta = (netYield * 1e18 * cfg.orbitMultiplier) / (state.totalShares * 1e18);
            state.accumulatedYieldPerShare += accDelta;
        }
        state.lastOrbitBlock = block.number;

        emit Orbit(ringIndex, yieldAmount, fee);
    }

    function harvest(uint256 ringIndex) external nonReentrant {
        if (ringIndex >= RING_COUNT) revert Loopy__InvalidRing();

        Position storage pos = _positions[ringIndex][msg.sender];
        RingState storage state = _ringStates[ringIndex];

        uint256 pending = (pos.shares * state.accumulatedYieldPerShare) / 1e18 - pos.rewardDebt;
        if (pending == 0) return;

        pos.rewardDebt = (pos.shares * state.accumulatedYieldPerShare) / 1e18;

        uint256 bal = lpToken.balanceOf(address(this));
        uint256 send = pending > bal ? bal : pending;
        if (send > 0) {
            lpToken.transfer(msg.sender, send);
        }
    }

    function migrateRing(uint256 fromRing, uint256 toRing, uint256 shares) external nonReentrant whenNotPaused {
        if (fromRing >= RING_COUNT || toRing >= RING_COUNT || fromRing == toRing) revert Loopy__InvalidRing();

        Position storage fromPos = _positions[fromRing][msg.sender];
        if (shares > fromPos.shares) revert Loopy__InsufficientShares();

        RingConfig memory fromCfg = _ringConfigs[fromRing];
        if (block.number < fromPos.depositBlock + fromCfg.minLockBlocks) revert Loopy__Locked();

        RingState storage fromState = _ringStates[fromRing];
        uint256 assets = (shares * fromState.totalDeposited) / fromState.totalShares;

        RingState storage toState = _ringStates[toRing];
        uint256 cap = maxDepositPerRing;
        if (toState.totalDeposited + assets > cap) revert Loopy__ExceedsMaxDeposit();

        uint256 pending = (fromPos.shares * fromState.accumulatedYieldPerShare) / 1e18 - fromPos.rewardDebt;
        fromPos.rewardDebt = ((fromPos.shares - shares) * fromState.accumulatedYieldPerShare) / 1e18;
        fromPos.shares -= shares;

        fromState.totalShares -= shares;
        fromState.totalDeposited -= assets;

        uint256 newShares = toState.totalShares == 0
            ? assets
            : (assets * toState.totalShares) / toState.totalDeposited;

        Position storage toPos = _positions[toRing][msg.sender];
        if (toPos.shares > 0) {
            toPos.rewardDebt = (toPos.shares * toState.accumulatedYieldPerShare) / 1e18;
        }

        toState.totalDeposited += assets;
        toState.totalShares += newShares;
        toPos.shares += newShares;
        toPos.depositBlock = block.number;
        toPos.rewardDebt = (toPos.shares * toState.accumulatedYieldPerShare) / 1e18;

        if (pending > 0) {
            uint256 bal = lpToken.balanceOf(address(this));
            if (pending <= bal) lpToken.transfer(msg.sender, pending);
        }

        emit RingMigrate(msg.sender, fromRing, toRing, shares);
    }

    function pendingReward(uint256 ringIndex, address user) external view returns (uint256) {
        if (ringIndex >= RING_COUNT) return 0;
        Position storage pos = _positions[ringIndex][user];
        RingState storage state = _ringStates[ringIndex];
        uint256 acc = state.accumulatedYieldPerShare;
        return (pos.shares * acc) / 1e18 - pos.rewardDebt;
    }

    function positionOf(uint256 ringIndex, address user) external view returns (uint256 shares, uint256 depositBlock) {
        if (ringIndex >= RING_COUNT) return (0, 0);
        Position storage pos = _positions[ringIndex][user];
        return (pos.shares, pos.depositBlock);
    }

    function ringConfig(uint256 ringIndex) external view returns (
        uint256 weightBps,
        uint256 feeBps,
        uint256 minLockBlocks,
        uint256 orbitMultiplier
    ) {
        if (ringIndex >= RING_COUNT) return (0, 0, 0, 0);
        RingConfig storage c = _ringConfigs[ringIndex];
        return (c.weightBps, c.feeBps, c.minLockBlocks, c.orbitMultiplier);
    }

    function ringState(uint256 ringIndex) external view returns (
        uint256 totalDeposited,
        uint256 totalShares,
        uint256 accumulatedYieldPerShare,
        uint256 lastOrbitBlock
    ) {
        if (ringIndex >= RING_COUNT) return (0, 0, 0, 0);
        RingState storage s = _ringStates[ringIndex];
        return (s.totalDeposited, s.totalShares, s.accumulatedYieldPerShare, s.lastOrbitBlock);
    }

    function sharesToAssets(uint256 ringIndex, uint256 shares) external view returns (uint256) {
        if (ringIndex >= RING_COUNT) return 0;
        RingState storage state = _ringStates[ringIndex];
        return state.totalShares == 0 ? 0 : (shares * state.totalDeposited) / state.totalShares;
    }

    function setPaused(bool paused_) external onlyOwner {
        _paused = paused_;
        emit PauseToggled(paused_);
    }

    function sweepFees(address token) external onlyOwner {
        if (token == address(lpToken)) {
            uint256 totalLocked = 0;
            for (uint256 i = 0; i < RING_COUNT; i++) {
                totalLocked += _ringStates[i].totalDeposited;
            }
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > totalLocked) {
                uint256 excess = bal - totalLocked;
                IERC20(token).transfer(feeRecipient, excess);
                emit FeeSweep(token, excess);
            }
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) {
                IERC20(token).transfer(feeRecipient, bal);
                emit FeeSweep(token, bal);
            }
        }
    }

    function totalDepositedAcrossRings() external view returns (uint256 total) {
        for (uint256 i = 0; i < RING_COUNT; i++) {
            total += _ringStates[i].totalDeposited;
        }
    }

    function canWithdraw(uint256 ringIndex, address user) external view returns (bool) {
        if (ringIndex >= RING_COUNT) return false;
        Position storage pos = _positions[ringIndex][user];
        if (pos.shares == 0) return false;
        RingConfig storage cfg = _ringConfigs[ringIndex];
        return block.number >= pos.depositBlock + cfg.minLockBlocks;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function blocksUntilUnlock(uint256 ringIndex, address user) external view returns (uint256) {
        if (ringIndex >= RING_COUNT) return type(uint256).max;
        Position storage pos = _positions[ringIndex][user];
        if (pos.shares == 0) return type(uint256).max;
        RingConfig storage cfg = _ringConfigs[ringIndex];
        uint256 unlockBlock = pos.depositBlock + cfg.minLockBlocks;
        return block.number >= unlockBlock ? 0 : unlockBlock - block.number;
    }

    function ringName(uint256 ringIndex) external pure returns (string memory) {
        if (ringIndex == 0) return "Core";
        if (ringIndex == 1) return "Mantle";
        if (ringIndex == 2) return "Crust";
        if (ringIndex == 3) return "Halo";
        if (ringIndex == 4) return "Void";
        return "";
    }

    function userSnapshot(address user) external view returns (
        uint256[RING_COUNT] memory sharesPerRing,
        uint256[RING_COUNT] memory pendingPerRing,
        uint256 totalShares,
        uint256 totalPending
    ) {
        for (uint256 i = 0; i < RING_COUNT; i++) {
            Position storage pos = _positions[i][user];
            RingState storage state = _ringStates[i];
            sharesPerRing[i] = pos.shares;
            uint256 pending = (pos.shares * state.accumulatedYieldPerShare) / 1e18 - pos.rewardDebt;
            pendingPerRing[i] = pending;
            totalShares += pos.shares;
            totalPending += pending;
        }
    }

    function ringSnapshot() external view returns (
        uint256[RING_COUNT] memory totalDepositedPerRing,
        uint256[RING_COUNT] memory totalSharesPerRing,
        uint256 grandTotalDeposited
    ) {
        for (uint256 i = 0; i < RING_COUNT; i++) {
            RingState storage s = _ringStates[i];
            totalDepositedPerRing[i] = s.totalDeposited;
            totalSharesPerRing[i] = s.totalShares;
            grandTotalDeposited += s.totalDeposited;
        }
    }

    function tierMultiplierBps(uint256 ringIndex) external view returns (uint256) {
        if (ringIndex >= RING_COUNT) return 0;
        RingConfig storage c = _ringConfigs[ringIndex];
        return (c.orbitMultiplier * BPS_DENOM) / 1e18;
    }

    function getRingIndices() external pure returns (uint256[] memory) {
        uint256[] memory indices = new uint256[](RING_COUNT);
        for (uint256 i = 0; i < RING_COUNT; i++) {
            indices[i] = i;
        }
        return indices;
    }
}

