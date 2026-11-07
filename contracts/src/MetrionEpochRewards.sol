// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MetrionEpochRewards
/// @notice Funded USDG rewards with a fee-allocation ceiling and automatic batches.
/// The designated worker verifies collected protocol fees and contribution evidence
/// off chain. This contract does NOT prove those receipts or the usefulness of work.
/// It bounds each worker-attested UTC epoch by an owner policy, reserves actual USDG,
/// and prevents a contribution from being paid twice. Separately, the owner can
/// authorize one finite pilot reserve at deployment; pilot funds are never fees.
/// Deposits alone allocate nothing, and cannot renew an exhausted pilot.
/// @dev USDG has six decimals. The owner funds with normal token transfers. Policy
/// changes apply to epochs not yet configured; previously committed budgets remain
/// reserved for their payouts. The owner may pause payments and withdraw unallocated
/// funds, but cannot withdraw committed unpaid budgets. There is no lifetime earnings
/// cap or claim expiry. Deployment values use storage for an identical runtime hash.
contract MetrionEpochRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant TOKEN = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 public constant CHAIN_ID = 4663;
    uint256 public constant EPOCH_SECONDS = 1 days;
    uint256 public constant MAX_BATCH = 25;
    uint256 public constant MAX_GAS_FUND = 0.002 ether;
    uint16 public constant MAX_ALLOCATION_BPS = 1_000;
    uint256 public constant MAX_EPOCH_CAP = type(uint128).max;
    uint256 public constant MAX_PILOT_CAP = 50_000_000;
    uint64 public constant PILOT_EPOCH = 0;
    bytes32 public constant PILOT_EVIDENCE = keccak256("METRION_PILOT_RESERVE_V1");

    struct Epoch {
        uint256 collectedFees;
        uint256 allocated;
        uint256 paid;
        uint256 cap;
        uint256 maxReward;
        uint16 allocationBps;
        bytes32 evidenceHash;
        bool configured;
    }

    struct Payment {
        bytes32 contributionId;
        address recipient;
        uint256 amount;
        bytes32 evidenceHash;
    }

    address public owner;
    address public worker;
    uint256 public epochCap;
    uint256 public maxReward;
    uint16 public allocationBps;
    bool public paused;
    uint256 public pilotCap;
    bool public pilotAllocated;
    uint256 public totalAllocated;
    uint256 public totalReserved;
    uint256 public totalPaid;
    mapping(uint64 epoch => Epoch) public epochs;
    mapping(uint256 utcDay => uint256 amount) public periodSpent;
    mapping(bytes32 contributionId => bool) public paidContributions;
    mapping(address recipient => uint256 amount) public recipientPaid;

    event EpochAllocated(
        uint64 indexed epoch,
        uint256 cumulativeCollectedFees,
        uint256 budget,
        uint256 added,
        uint16 allocationBps,
        bytes32 evidenceHash
    );
    event ContributionPaid(
        uint64 indexed epoch,
        bytes32 indexed contributionId,
        address indexed recipient,
        uint256 amount,
        bytes32 evidenceHash
    );
    event PolicyUpdated(uint256 epochCap, uint256 maxReward, uint16 allocationBps);
    event PilotAllocated(uint256 amount, bytes32 evidenceHash);
    event Paused(bool paused);
    event Withdrawn(address indexed to, uint256 amount);
    event WorkerGasFunded(address indexed worker, uint256 amount);

    error WrongChain();
    error InvalidWorker();
    error InvalidPolicy();
    error TokenUnavailable();
    error GasFundTooLarge();
    error GasFundingFailed();
    error NotOwner();
    error NotWorker();
    error RewardsPaused();
    error InvalidEpoch();
    error InvalidEvidence();
    error InvalidFeeAttestation();
    error InvalidBudget();
    error InsufficientFunding();
    error InvalidBatch();
    error InvalidContribution();
    error ContributionAlreadyPaid();
    error InvalidRecipient();
    error InvalidAmount();
    error EpochBudgetExceeded();
    error PayoutDayCapExceeded();
    error InvalidWithdrawal();
    error PilotAlreadyAllocated();
    error InvalidPilotAmount();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyWorker() {
        if (msg.sender != worker) revert NotWorker();
        _;
    }

    constructor(address worker_, uint256 epochCap_, uint256 maxReward_, uint16 allocationBps_, uint256 pilotCap_) payable {
        if (block.chainid != CHAIN_ID) revert WrongChain();
        if (worker_ == address(0) || worker_ == msg.sender || worker_ == address(this)) revert InvalidWorker();
        _validatePolicy(epochCap_, maxReward_, allocationBps_);
        if (pilotCap_ > MAX_PILOT_CAP) revert InvalidPilotAmount();
        if (TOKEN.code.length == 0) revert TokenUnavailable();
        if (msg.value > MAX_GAS_FUND) revert GasFundTooLarge();
        owner = msg.sender;
        worker = worker_;
        epochCap = epochCap_;
        maxReward = maxReward_;
        allocationBps = allocationBps_;
        pilotCap = pilotCap_;
        emit PolicyUpdated(epochCap_, maxReward_, allocationBps_);
        if (msg.value != 0) {
            (bool sent,) = worker_.call{value: msg.value, gas: 30_000}("");
            if (!sent) revert GasFundingFailed();
            emit WorkerGasFunded(worker_, msg.value);
        }
    }

    /// @notice Commit the finite pilot reserve authorized in the constructor.
    /// This is not protocol revenue. It can be allocated once only, within the
    /// original pilot cap and actual unallocated USDG balance. Later deposits,
    /// policy changes and UTC days cannot refill or restart this pilot.
    /// @dev Epoch zero is reserved exclusively for pilot work. The same worker,
    /// contribution replay guards, payout-day cap and recipient rules apply.
    function allocatePilot(uint256 amount) external onlyWorker nonReentrant {
        if (paused) revert RewardsPaused();
        if (pilotAllocated) revert PilotAlreadyAllocated();
        if (amount == 0 || amount > pilotCap) revert InvalidPilotAmount();
        uint256 reserved = totalReserved + amount;
        if (IERC20(TOKEN).balanceOf(address(this)) < reserved) revert InsufficientFunding();
        pilotAllocated = true;
        epochs[PILOT_EPOCH] = Epoch({
            collectedFees: 0,
            allocated: amount,
            paid: 0,
            cap: amount,
            maxReward: maxReward,
            allocationBps: 0,
            evidenceHash: PILOT_EVIDENCE,
            configured: true
        });
        totalReserved = reserved;
        totalAllocated += amount;
        emit PilotAllocated(amount, PILOT_EVIDENCE);
    }

    /// @notice Commit an explicit budget within an epoch's share of cumulative
    /// worker-attested collected protocol USDG fees. Unassigned shares stay free.
    /// @dev Every qualifying fee must belong to one epoch only; this cross-epoch
    /// source uniqueness is checked by the trusted verifier's durable fee ledger.
    /// A deposit or attestation never authorizes spending more than funded USDG.
    /// Past epochs remain allocatable after finality delays or outages. The worker
    /// must preserve each receipt's assigned recognition epoch across retries;
    /// a hash is not an on-chain fee proof. Epoch zero belongs only to the pilot.
    function allocate(
        uint64 epoch,
        uint256 cumulativeCollectedFeeAtomic,
        uint256 cumulativeBudgetAtomic,
        bytes32 evidenceHash
    )
        external
        onlyWorker
        nonReentrant
        returns (uint256 budget)
    {
        if (paused) revert RewardsPaused();
        if (epoch == PILOT_EPOCH || uint256(epoch) > block.timestamp / EPOCH_SECONDS) revert InvalidEpoch();
        if (evidenceHash == bytes32(0)) revert InvalidEvidence();
        if (cumulativeCollectedFeeAtomic == 0 || cumulativeCollectedFeeAtomic > type(uint128).max) {
            revert InvalidFeeAttestation();
        }
        Epoch storage terms = epochs[epoch];
        if (!terms.configured) {
            terms.cap = epochCap;
            terms.maxReward = maxReward;
            terms.allocationBps = allocationBps;
            terms.configured = true;
        } else {
            if (cumulativeCollectedFeeAtomic < terms.collectedFees) revert InvalidFeeAttestation();
            if (cumulativeBudgetAtomic < terms.allocated) revert InvalidBudget();
            if (cumulativeCollectedFeeAtomic == terms.collectedFees && cumulativeBudgetAtomic == terms.allocated) {
                if (evidenceHash != terms.evidenceHash) revert InvalidFeeAttestation();
                return terms.allocated;
            }
        }

        uint256 ceiling = cumulativeCollectedFeeAtomic * terms.allocationBps / 10_000;
        if (ceiling > terms.cap) ceiling = terms.cap;
        if (cumulativeBudgetAtomic > ceiling) revert InvalidBudget();
        budget = cumulativeBudgetAtomic;
        uint256 added = budget - terms.allocated;
        uint256 reserved = totalReserved + added;
        if (IERC20(TOKEN).balanceOf(address(this)) < reserved) revert InsufficientFunding();

        terms.collectedFees = cumulativeCollectedFeeAtomic;
        terms.allocated = budget;
        terms.evidenceHash = evidenceHash;
        totalReserved = reserved;
        totalAllocated += added;
        emit EpochAllocated(epoch, cumulativeCollectedFeeAtomic, budget, added, terms.allocationBps, evidenceHash);
    }

    /// @notice Settle up to 25 verified contributions from one committed epoch.
    /// Old funded epochs remain payable after outages, within the actual payout
    /// day's owner cap across every source epoch. All recipients receive
    /// direct USDG transfers; no owner signature or recipient claim is required.
    /// @dev Every evidence hash is an external-verifier attestation commitment.
    /// This contract cannot independently determine whether the work was useful.
    function payBatch(uint64 epoch, Payment[] calldata payments) external onlyWorker nonReentrant {
        if (paused) revert RewardsPaused();
        Epoch storage terms = epochs[epoch];
        if (!terms.configured) revert InvalidEpoch();
        uint256 length = payments.length;
        if (length == 0 || length > MAX_BATCH) revert InvalidBatch();
        uint256 amount;
        for (uint256 i; i < length; ++i) {
            Payment calldata payment = payments[i];
            if (payment.contributionId == bytes32(0)) revert InvalidContribution();
            if (paidContributions[payment.contributionId]) revert ContributionAlreadyPaid();
            if (payment.evidenceHash == bytes32(0)) revert InvalidEvidence();
            if (payment.recipient == address(0) || payment.recipient == owner || payment.recipient == worker
                || payment.recipient == address(this)) revert InvalidRecipient();
            if (payment.amount == 0 || payment.amount > terms.maxReward) revert InvalidAmount();
            amount += payment.amount;
            paidContributions[payment.contributionId] = true;
            recipientPaid[payment.recipient] += payment.amount;
        }
        if (amount > terms.allocated - terms.paid) revert EpochBudgetExceeded();
        uint256 day = block.timestamp / EPOCH_SECONDS;
        uint256 spent = periodSpent[day];
        if (amount > epochCap || spent > epochCap - amount) revert PayoutDayCapExceeded();
        if (IERC20(TOKEN).balanceOf(address(this)) < totalReserved) revert InsufficientFunding();
        terms.paid += amount;
        periodSpent[day] = spent + amount;
        totalReserved -= amount;
        totalPaid += amount;

        for (uint256 i; i < length; ++i) {
            Payment calldata payment = payments[i];
            IERC20(TOKEN).safeTransfer(payment.recipient, payment.amount);
            emit ContributionPaid(epoch, payment.contributionId, payment.recipient, payment.amount, payment.evidenceHash);
        }
    }

    function epochAvailable(uint64 epoch) external view returns (uint256) {
        Epoch storage terms = epochs[epoch];
        return terms.allocated - terms.paid;
    }

    function availableToAllocate() public view returns (uint256) {
        uint256 balance = IERC20(TOKEN).balanceOf(address(this));
        return balance > totalReserved ? balance - totalReserved : 0;
    }

    function pause(bool value) external onlyOwner nonReentrant {
        paused = value;
        emit Paused(value);
    }

    /// @notice Configure future allocations and the maximum paid per UTC day.
    /// Existing budgets and per-contribution ceilings never change retroactively;
    /// the current payout-day cap applies across all epochs without resetting spent.
    /// A zero percentage disables allocation for future epochs; deposits alone
    /// cannot bypass it. Pause provides an immediate stop for all epochs.
    function setPolicy(uint256 epochCap_, uint256 maxReward_, uint16 allocationBps_)
        external
        onlyOwner
        nonReentrant
    {
        _validatePolicy(epochCap_, maxReward_, allocationBps_);
        epochCap = epochCap_;
        maxReward = maxReward_;
        allocationBps = allocationBps_;
        emit PolicyUpdated(epochCap_, maxReward_, allocationBps_);
    }

    /// @notice Pause and withdraw unallocated USDG, preserving committed budgets.
    function withdraw(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this) || amount == 0) revert InvalidWithdrawal();
        if (amount > availableToAllocate()) revert InsufficientFunding();
        paused = true;
        emit Paused(true);
        IERC20(TOKEN).safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @notice Pause and recover all unallocated funds. Allocated unpaid USDG
    /// remains reserved even when the treasury stops commissioning new work.
    function withdrawUnallocated(address to) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidWithdrawal();
        uint256 amount = availableToAllocate();
        paused = true;
        emit Paused(true);
        if (amount != 0) IERC20(TOKEN).safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    function _validatePolicy(uint256 cap, uint256 reward, uint16 bps) private pure {
        if (cap == 0 || cap > MAX_EPOCH_CAP || reward == 0 || reward > cap || bps > MAX_ALLOCATION_BPS) {
            revert InvalidPolicy();
        }
    }
}
