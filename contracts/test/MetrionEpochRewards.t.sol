// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MetrionEpochRewards} from "../src/MetrionEpochRewards.sol";

contract EpochRewardsTokenMock {
    mapping(address => uint256) public balanceOf;
    uint256 public transfers;
    uint256 public failAt;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function burn(address from, uint256 amount) external { balanceOf[from] -= amount; }
    function failTransfer(uint256 at) external { failAt = at; }
    function callback(address target, bytes memory data) external { callbackTarget = target; callbackData = data; }
    function transfer(address to, uint256 amount) external returns (bool) {
        transfers++;
        if (failAt != 0 && transfers == failAt) return false;
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (callbackTarget != address(0)) {
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
        return true;
    }
    function callAsWorker(address target, bytes memory data) external returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
}

contract EpochRewardsRejectEth {
    receive() external payable { revert("reject"); }
}

contract MetrionEpochRewardsTest is Test {
    address constant TOKEN = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 constant DAY = 86_400;
    uint256 constant CAP = 5_000_000;
    uint256 constant MAX_REWARD = 1_000_000;
    uint16 constant BPS = 100;
    uint256 constant PILOT_CAP = 44_000_000;
    bytes32 constant FEES = keccak256("canonical collected protocol USDG receipts");
    bytes32 constant WORK = keccak256("independently accepted contribution evidence");
    address worker = makeAddr("bounded-fee-verifier");
    address provider = makeAddr("provider");
    address referrer = makeAddr("referrer");
    address stranger = makeAddr("stranger");
    MetrionEpochRewards vault;
    EpochRewardsTokenMock token;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(100 * DAY + 1_800);
        vm.deal(address(this), 1 ether);
        vm.etch(TOKEN, address(new EpochRewardsTokenMock()).code);
        token = EpochRewardsTokenMock(TOKEN);
        vault = new MetrionEpochRewards(worker, CAP, MAX_REWARD, BPS, PILOT_CAP);
        token.mint(address(vault), 50_000_000);
    }

    function epoch() internal view returns (uint64) { return uint64(block.timestamp / DAY); }
    function contribution(uint256 n) internal pure returns (bytes32) { return keccak256(abi.encode("contribution", n)); }
    function terms(uint64 id) internal view returns (MetrionEpochRewards.Epoch memory out) {
        (out.collectedFees, out.allocated, out.paid, out.cap, out.maxReward, out.allocationBps, out.evidenceHash, out.configured) = vault.epochs(id);
    }
    function allocate(uint64 id, uint256 fees, uint256 budget) internal {
        vm.prank(worker);
        vault.allocate(id, fees, budget, FEES);
    }
    function payment(uint256 id, address to, uint256 amount) internal pure returns (MetrionEpochRewards.Payment memory) {
        return MetrionEpochRewards.Payment(contribution(id), to, amount, WORK);
    }
    function batch(uint64 id, MetrionEpochRewards.Payment[] memory payments) internal {
        vm.prank(worker);
        vault.payBatch(id, payments);
    }
    function pay(uint64 id, uint256 job, address to, uint256 amount) internal {
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](1);
        payments[0] = payment(job, to, amount);
        batch(id, payments);
    }

    function test_constructorPinsAndRuntimeIndependentOfPolicyAndOwner() public {
        assertEq(vault.owner(), address(this));
        assertEq(vault.worker(), worker);
        assertEq(vault.TOKEN(), TOKEN);
        assertEq(vault.CHAIN_ID(), 4663);
        assertEq(vault.EPOCH_SECONDS(), DAY);
        assertEq(vault.MAX_BATCH(), 25);
        assertEq(vault.epochCap(), CAP);
        assertEq(vault.maxReward(), MAX_REWARD);
        assertEq(vault.allocationBps(), 100);
        assertEq(vault.pilotCap(), PILOT_CAP);
        assertFalse(vault.pilotAllocated());
        vm.prank(stranger);
        MetrionEpochRewards other = new MetrionEpochRewards(referrer, 10_000_000, 2_000_000, 200, PILOT_CAP);
        assertEq(other.owner(), stranger);
        assertEq(address(vault).codehash, address(other).codehash);
    }

    function test_constructorRejectsInvalidNetworkWorkerTokenAndPolicy() public {
        vm.chainId(1);
        vm.expectRevert(MetrionEpochRewards.WrongChain.selector);
        new MetrionEpochRewards(worker, CAP, MAX_REWARD, BPS, PILOT_CAP);
        vm.chainId(4663);
        vm.expectRevert(MetrionEpochRewards.InvalidWorker.selector);
        new MetrionEpochRewards(address(0), CAP, MAX_REWARD, BPS, PILOT_CAP);
        vm.expectRevert(MetrionEpochRewards.InvalidWorker.selector);
        new MetrionEpochRewards(address(this), CAP, MAX_REWARD, BPS, PILOT_CAP);
        vm.expectRevert(MetrionEpochRewards.InvalidPolicy.selector);
        new MetrionEpochRewards(worker, 0, 1, BPS, PILOT_CAP);
        vm.expectRevert(MetrionEpochRewards.InvalidPolicy.selector);
        new MetrionEpochRewards(worker, CAP, 0, BPS, PILOT_CAP);
        vm.expectRevert(MetrionEpochRewards.InvalidPolicy.selector);
        new MetrionEpochRewards(worker, CAP, CAP + 1, BPS, PILOT_CAP);
        vm.expectRevert(MetrionEpochRewards.InvalidPolicy.selector);
        new MetrionEpochRewards(worker, CAP, MAX_REWARD, 1_001, PILOT_CAP);
        vm.expectRevert(MetrionEpochRewards.InvalidPolicy.selector);
        new MetrionEpochRewards(worker, uint256(type(uint128).max) + 1, MAX_REWARD, BPS, PILOT_CAP);
        vm.etch(TOKEN, "");
        vm.expectRevert(MetrionEpochRewards.TokenUnavailable.selector);
        new MetrionEpochRewards(worker, CAP, MAX_REWARD, BPS, PILOT_CAP);
    }

    function test_optionalWorkerGasIsBoundedAndMustSucceed() public {
        uint256 before = worker.balance;
        MetrionEpochRewards funded = new MetrionEpochRewards{value: 0.002 ether}(worker, CAP, MAX_REWARD, BPS, PILOT_CAP);
        assertEq(worker.balance - before, 0.002 ether);
        assertEq(address(funded).balance, 0);
        vm.expectRevert(MetrionEpochRewards.GasFundTooLarge.selector);
        new MetrionEpochRewards{value: 0.002 ether + 1}(worker, CAP, MAX_REWARD, BPS, PILOT_CAP);
        EpochRewardsRejectEth rejector = new EpochRewardsRejectEth();
        vm.expectRevert(MetrionEpochRewards.GasFundingFailed.selector);
        new MetrionEpochRewards{value: 1}(address(rejector), CAP, MAX_REWARD, BPS, PILOT_CAP);
    }

    function test_depositsDoNotCreateFeeRevenueOrPaymentAuthority() public {
        assertEq(vault.availableToAllocate(), 50_000_000);
        assertEq(vault.totalAllocated(), 0);
        assertEq(vault.totalReserved(), 0);
        vm.expectRevert(MetrionEpochRewards.InvalidEpoch.selector);
        pay(epoch(), 1, provider, 100_000);
        assertEq(token.balanceOf(provider), 0);
    }

    function test_pilotCommitmentIsExplicitFiniteReserveNeverFeeRevenue() public {
        vm.recordLogs();
        vm.prank(worker);
        vault.allocatePilot(PILOT_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("PilotAllocated(uint256,bytes32)"));
        (uint256 amount, bytes32 evidence) = abi.decode(logs[0].data, (uint256, bytes32));
        assertEq(amount, PILOT_CAP);
        assertEq(evidence, vault.PILOT_EVIDENCE());
        assertTrue(vault.pilotAllocated());
        MetrionEpochRewards.Epoch memory pilot = terms(0);
        assertEq(pilot.collectedFees, 0);
        assertEq(pilot.allocationBps, 0);
        assertEq(pilot.cap, PILOT_CAP);
        assertEq(pilot.maxReward, MAX_REWARD);
        assertEq(pilot.allocated, PILOT_CAP);
        assertEq(vault.totalReserved(), PILOT_CAP);
        assertEq(vault.totalAllocated(), PILOT_CAP);
        assertEq(vault.availableToAllocate(), 6_000_000);
        assertTrue(pilot.configured);
        vm.expectRevert(MetrionEpochRewards.InvalidEpoch.selector);
        allocate(0, 1_000_000_000, PILOT_CAP);
    }

    function test_pilotCeilingCannotBeRaisedAndZeroDisablesPilot() public {
        vm.expectRevert(MetrionEpochRewards.InvalidPilotAmount.selector);
        new MetrionEpochRewards(worker, CAP, MAX_REWARD, BPS, 50_000_001);
        MetrionEpochRewards disabled = new MetrionEpochRewards(worker, CAP, MAX_REWARD, BPS, 0);
        token.mint(address(disabled), 50_000_000);
        vm.prank(worker);
        vm.expectRevert(MetrionEpochRewards.InvalidPilotAmount.selector);
        disabled.allocatePilot(1);
        vault.setPolicy(100_000_000, 100_000_000, 1_000);
        assertEq(vault.pilotCap(), PILOT_CAP);
        vm.prank(worker);
        vm.expectRevert(MetrionEpochRewards.InvalidPilotAmount.selector);
        vault.allocatePilot(PILOT_CAP + 1);
        vm.prank(worker);
        vm.expectRevert(MetrionEpochRewards.InvalidPilotAmount.selector);
        vault.allocatePilot(0);
        assertFalse(vault.pilotAllocated());
    }

    function test_pilotOnlyWorkerAndPauseApplies() public {
        vm.expectRevert(MetrionEpochRewards.NotWorker.selector);
        vault.allocatePilot(100_000);
        vm.prank(stranger);
        vm.expectRevert(MetrionEpochRewards.NotWorker.selector);
        vault.allocatePilot(100_000);
        vault.pause(true);
        vm.prank(worker);
        vm.expectRevert(MetrionEpochRewards.RewardsPaused.selector);
        vault.allocatePilot(100_000);
        assertFalse(vault.pilotAllocated());
        vault.pause(false);
        vm.prank(worker);
        vault.allocatePilot(100_000);
        vault.pause(true);
        vm.expectRevert(MetrionEpochRewards.RewardsPaused.selector);
        pay(0, 1, provider, 100_000);
    }

    function test_pilotFundingMustCoverAllExistingCommittedBudgets() public {
        allocate(epoch(), 500_000_000, CAP);
        token.burn(address(vault), 2_000_000);
        vm.prank(worker);
        vm.expectRevert(MetrionEpochRewards.InsufficientFunding.selector);
        vault.allocatePilot(PILOT_CAP);
        assertFalse(vault.pilotAllocated());
        assertFalse(terms(0).configured);
        token.mint(address(vault), 1_000_000);
        vm.prank(worker);
        vault.allocatePilot(PILOT_CAP);
        assertEq(vault.totalReserved(), 49_000_000);
        assertEq(vault.availableToAllocate(), 0);
        vm.expectRevert(MetrionEpochRewards.InsufficientFunding.selector);
        vault.withdraw(1, address(this));
    }

    function test_pilotExhaustionCannotResetByDepositDayPolicyOrPause() public {
        vm.prank(worker);
        vault.allocatePilot(200_000);
        pay(0, 1, provider, 200_000);
        assertEq(vault.epochAvailable(0), 0);
        vm.expectRevert(MetrionEpochRewards.EpochBudgetExceeded.selector);
        pay(0, 2, provider, 1);
        token.mint(address(vault), 50_000_000);
        vm.warp(block.timestamp + 100 days);
        vault.setPolicy(10_000_000, 2_000_000, 200);
        vault.pause(true);
        vault.pause(false);
        vm.prank(worker);
        vm.expectRevert(MetrionEpochRewards.PilotAlreadyAllocated.selector);
        vault.allocatePilot(PILOT_CAP);
        assertEq(vault.totalAllocated(), 200_000);
        assertEq(vault.recipientPaid(provider), 200_000);
    }

    function test_pilotAndFeePayoutsShareCurrentDailyCapAndGlobalReplayGuard() public {
        vm.prank(worker);
        vault.allocatePilot(CAP);
        allocate(epoch(), 500_000_000, CAP);
        for (uint256 i; i < 4; ++i) pay(0, i, provider, MAX_REWARD);
        pay(epoch(), 4, referrer, MAX_REWARD);
        assertEq(vault.periodSpent(epoch()), CAP);
        vm.expectRevert(MetrionEpochRewards.PayoutDayCapExceeded.selector);
        pay(0, 5, provider, MAX_REWARD);
        vm.warp(block.timestamp + DAY);
        pay(0, 5, provider, MAX_REWARD);
        vm.expectRevert(MetrionEpochRewards.ContributionAlreadyPaid.selector);
        pay(epoch() - 1, 5, referrer, MAX_REWARD);
        assertEq(vault.epochAvailable(0), 0);
        assertEq(vault.recipientPaid(provider), CAP);
        assertEq(vault.periodSpent(epoch()), MAX_REWARD);
        assertEq(vault.totalPaid(), 6_000_000);
    }

    function test_pilotRetainsEarnedPolicyAndUnpaidReserve() public {
        vm.prank(worker);
        vault.allocatePilot(1_000_000);
        vault.setPolicy(CAP, 100_000, 0);
        vault.withdrawUnallocated(address(this));
        assertEq(token.balanceOf(address(vault)), 1_000_000);
        vault.pause(false);
        pay(0, 1, provider, MAX_REWARD);
        assertEq(vault.totalPaid(), MAX_REWARD);
        assertEq(vault.totalReserved(), 0);
    }

    function testFuzz_pilotActualCommitmentNeverExceedsOwnerCeiling(uint256 amount) public {
        amount = bound(amount, 1, PILOT_CAP);
        vm.prank(worker);
        vault.allocatePilot(amount);
        assertEq(vault.totalReserved(), amount);
        assertEq(vault.totalAllocated(), amount);
        assertEq(vault.availableToAllocate(), 50_000_000 - amount);
        assertEq(terms(0).collectedFees, 0);
        vm.prank(worker);
        vm.expectRevert(MetrionEpochRewards.PilotAlreadyAllocated.selector);
        vault.allocatePilot(1);
    }

    function test_explicitBudgetLeavesUnassignedReferralShareUnallocated() public {
        // 100 USDG actual fee attestation permits 1 USDG maximum; only the
        // 0.50 maintenance share is committed until a referral actually qualifies.
        allocate(epoch(), 100_000_000, 500_000);
        assertEq(vault.totalAllocated(), 500_000);
        assertEq(vault.totalReserved(), 500_000);
        assertEq(vault.availableToAllocate(), 49_500_000);
        assertEq(terms(epoch()).collectedFees, 100_000_000);
        assertEq(vault.epochAvailable(epoch()), 500_000);
        allocate(epoch(), 100_000_000, 700_000);
        assertEq(vault.totalReserved(), 700_000);
        assertEq(vault.availableToAllocate(), 49_300_000);
    }

    function test_allocationCeilingUsesIntegerPercentageAndOwnerEpochCap() public {
        vm.expectRevert(MetrionEpochRewards.InvalidBudget.selector);
        allocate(epoch(), 1_234_599, 12_346);
        allocate(epoch(), 1_234_599, 12_345);
        vm.expectRevert(MetrionEpochRewards.InvalidBudget.selector);
        allocate(epoch(), 1_000_000_000, CAP + 1);
        allocate(epoch(), 1_000_000_000, CAP);
        assertEq(vault.totalAllocated(), CAP);
        assertEq(vault.epochAvailable(epoch()), CAP);
    }

    function test_allocationRetryIsIdempotentAndCannotRewriteSameAttestation() public {
        allocate(epoch(), 100_000_000, 500_000);
        allocate(epoch(), 100_000_000, 500_000);
        assertEq(vault.totalAllocated(), 500_000);
        assertEq(vault.totalReserved(), 500_000);
        vm.prank(worker);
        vm.expectRevert(MetrionEpochRewards.InvalidFeeAttestation.selector);
        vault.allocate(epoch(), 100_000_000, 500_000, keccak256("different receipts for same attestation"));
    }

    function test_cumulativeRevenueAndBudgetNeverDecreaseAfterPayment() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        pay(epoch(), 1, provider, 500_000);
        vm.expectRevert(MetrionEpochRewards.InvalidFeeAttestation.selector);
        allocate(epoch(), 99_999_999, 1_000_000);
        vm.expectRevert(MetrionEpochRewards.InvalidBudget.selector);
        allocate(epoch(), 100_000_000, 500_000);
        allocate(epoch(), 150_000_000, 1_500_000);
        assertEq(vault.totalAllocated(), 1_500_000);
        assertEq(vault.totalReserved(), 1_000_000);
        assertEq(terms(epoch()).paid, 500_000);
    }

    function test_oldEpochCanBeFundedAfterFinalityDelayAndPaidAfterLongOutage() public {
        uint64 original = epoch();
        vm.warp(block.timestamp + 90 days);
        allocate(original, 50_000_000, 500_000);
        pay(original, 1, provider, 500_000);
        assertEq(terms(original).paid, 500_000);
        assertFalse(terms(epoch()).configured);
        assertEq(vault.recipientPaid(provider), 500_000);
    }

    function test_futureEpochRejectedUntilExactUtcBoundary() public {
        uint64 next = epoch() + 1;
        vm.warp(uint256(next) * DAY - 1);
        vm.expectRevert(MetrionEpochRewards.InvalidEpoch.selector);
        allocate(next, 10_000_000, 100_000);
        vm.warp(uint256(next) * DAY);
        allocate(next, 10_000_000, 100_000);
        assertEq(vault.epochAvailable(next), 100_000);
    }

    function test_allocationRequiresNonzeroBoundedFeesAndEvidence() public {
        vm.expectRevert(MetrionEpochRewards.InvalidFeeAttestation.selector);
        allocate(epoch(), 0, 0);
        vm.expectRevert(MetrionEpochRewards.InvalidFeeAttestation.selector);
        allocate(epoch(), uint256(type(uint128).max) + 1, 0);
        vm.prank(worker);
        vm.expectRevert(MetrionEpochRewards.InvalidEvidence.selector);
        vault.allocate(epoch(), 1_000_000, 10_000, bytes32(0));
        assertFalse(terms(epoch()).configured);
    }

    function test_allocationCannotDoubleReserveTokenBalanceAcrossEpochs() public {
        vault.withdrawUnallocated(address(this));
        vault.pause(false);
        token.mint(address(vault), 1_000_000);
        allocate(epoch(), 100_000_000, 700_000);
        vm.warp(block.timestamp + DAY);
        vm.expectRevert(MetrionEpochRewards.InsufficientFunding.selector);
        allocate(epoch(), 100_000_000, 400_000);
        assertFalse(terms(epoch()).configured);
        assertEq(vault.totalReserved(), 700_000);
        allocate(epoch(), 100_000_000, 300_000);
        assertEq(vault.totalReserved(), 1_000_000);
        assertEq(vault.availableToAllocate(), 0);
    }

    function test_paysMultipleProvidersDirectlyWithExactEvidenceReceipts() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](2);
        payments[0] = payment(1, provider, 500_000);
        payments[1] = payment(2, referrer, 200_000);
        vm.recordLogs();
        batch(epoch(), payments);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        for (uint256 i; i < 2; ++i) {
            assertEq(logs[i].emitter, address(vault));
            assertEq(logs[i].topics[0], keccak256("ContributionPaid(uint64,bytes32,address,uint256,bytes32)"));
            assertEq(uint256(logs[i].topics[1]), epoch());
            assertEq(logs[i].topics[2], payments[i].contributionId);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), payments[i].recipient);
            assertEq(logs[i].data, abi.encode(payments[i].amount, WORK));
        }
        assertEq(token.balanceOf(provider), 500_000);
        assertEq(token.balanceOf(referrer), 200_000);
        assertEq(vault.recipientPaid(provider), 500_000);
        assertEq(vault.recipientPaid(referrer), 200_000);
        assertEq(vault.totalPaid(), 700_000);
        assertEq(vault.totalReserved(), 300_000);
        assertEq(vault.availableToAllocate(), 49_000_000);
        assertEq(terms(epoch()).paid, 700_000);
    }

    function test_batchLimitAllows25AndRejectsEmptyOr26() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](25);
        for (uint256 i; i < 25; ++i) payments[i] = payment(i, provider, 1_000);
        batch(epoch(), payments);
        assertEq(vault.totalPaid(), 25_000);
        payments = new MetrionEpochRewards.Payment[](26);
        vm.expectRevert(MetrionEpochRewards.InvalidBatch.selector);
        batch(epoch(), payments);
        payments = new MetrionEpochRewards.Payment[](0);
        vm.expectRevert(MetrionEpochRewards.InvalidBatch.selector);
        batch(epoch(), payments);
    }

    function test_duplicateContributionInBatchRevertsEveryEntry() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](2);
        payments[0] = payment(1, provider, 100_000);
        payments[1] = payment(1, referrer, 100_000);
        vm.expectRevert(MetrionEpochRewards.ContributionAlreadyPaid.selector);
        batch(epoch(), payments);
        assertEq(token.balanceOf(provider), 0);
        assertEq(vault.totalPaid(), 0);
        assertEq(vault.totalReserved(), 1_000_000);
        assertFalse(vault.paidContributions(contribution(1)));
    }

    function test_globalContributionReplayRejectedAcrossEpochsAndRecipients() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        pay(epoch(), 1, provider, 500_000);
        vm.warp(block.timestamp + DAY);
        allocate(epoch(), 100_000_000, 1_000_000);
        vm.expectRevert(MetrionEpochRewards.ContributionAlreadyPaid.selector);
        pay(epoch(), 1, referrer, 500_000);
        assertEq(vault.recipientPaid(referrer), 0);
        assertEq(terms(epoch()).paid, 0);
    }

    function test_batchCannotExceedPerContributionOrRemainingEpochBudget() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        vm.expectRevert(MetrionEpochRewards.InvalidAmount.selector);
        pay(epoch(), 1, provider, MAX_REWARD + 1);
        pay(epoch(), 1, provider, 700_000);
        vm.expectRevert(MetrionEpochRewards.EpochBudgetExceeded.selector);
        pay(epoch(), 2, referrer, 300_001);
        assertFalse(vault.paidContributions(contribution(2)));
        pay(epoch(), 2, referrer, 300_000);
        assertEq(vault.epochAvailable(epoch()), 0);
        vm.expectRevert(MetrionEpochRewards.EpochBudgetExceeded.selector);
        pay(epoch(), 3, provider, 1);
    }

    function test_invalidContributionEvidenceRecipientOrZeroAmountDoesNotConsumeCredit() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        address[4] memory forbidden = [address(0), address(this), worker, address(vault)];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.expectRevert(MetrionEpochRewards.InvalidRecipient.selector);
            pay(epoch(), 1, forbidden[i], 100_000);
        }
        vm.expectRevert(MetrionEpochRewards.InvalidAmount.selector);
        pay(epoch(), 1, provider, 0);
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](1);
        payments[0] = payment(1, provider, 100_000);
        payments[0].contributionId = bytes32(0);
        vm.expectRevert(MetrionEpochRewards.InvalidContribution.selector);
        batch(epoch(), payments);
        payments[0] = payment(1, provider, 100_000);
        payments[0].evidenceHash = bytes32(0);
        vm.expectRevert(MetrionEpochRewards.InvalidEvidence.selector);
        batch(epoch(), payments);
        assertEq(vault.totalPaid(), 0);
        assertFalse(vault.paidContributions(contribution(1)));
    }

    function test_laterFailedTransferRollsBackEarlierTransferAndAllAccounting() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](2);
        payments[0] = payment(1, provider, 500_000);
        payments[1] = payment(2, referrer, 200_000);
        token.failTransfer(2);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, TOKEN));
        batch(epoch(), payments);
        assertEq(token.balanceOf(provider), 0);
        assertEq(token.balanceOf(referrer), 0);
        assertEq(token.transfers(), 0);
        assertEq(vault.totalPaid(), 0);
        assertEq(vault.totalReserved(), 1_000_000);
        assertEq(vault.recipientPaid(provider), 0);
        assertFalse(vault.paidContributions(contribution(1)));
        assertFalse(vault.paidContributions(contribution(2)));
        token.failTransfer(0);
        batch(epoch(), payments);
        assertEq(vault.totalPaid(), 700_000);
    }

    function test_externalFundingShortfallFailsClosedWithoutConsumingContribution() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        token.burn(address(vault), 49_500_000);
        vm.expectRevert(MetrionEpochRewards.InsufficientFunding.selector);
        pay(epoch(), 1, provider, 100_000);
        assertFalse(vault.paidContributions(contribution(1)));
        token.mint(address(vault), 500_000);
        pay(epoch(), 1, provider, 100_000);
        assertEq(vault.totalReserved(), 900_000);
    }

    function test_policyChangesCannotResetOrIncreaseAnExistingEpoch() public {
        uint64 first = epoch();
        allocate(first, 100_000_000, 1_000_000);
        vault.setPolicy(10_000_000, 2_000_000, 200);
        assertEq(terms(first).cap, CAP);
        assertEq(terms(first).maxReward, MAX_REWARD);
        assertEq(terms(first).allocationBps, 100);
        vm.expectRevert(MetrionEpochRewards.InvalidBudget.selector);
        allocate(first, 100_000_000, 2_000_000);
        vm.warp(block.timestamp + DAY);
        allocate(epoch(), 100_000_000, 2_000_000);
        assertEq(terms(epoch()).allocationBps, 200);
        pay(epoch(), 2, provider, 2_000_000);
        vault.setPolicy(500_000, 100_000, 50);
        vm.expectRevert(MetrionEpochRewards.PayoutDayCapExceeded.selector);
        pay(first, 1, provider, 1_000_000);
        vault.setPolicy(4_000_000, 100_000, 50);
        pay(first, 1, provider, 1_000_000);
        assertEq(vault.recipientPaid(provider), 3_000_000);
    }

    function test_payoutDayCapCombinesOldAndCurrentEpochsAndRenewsNextDay() public {
        uint64 first = epoch();
        allocate(first, 500_000_000, CAP);
        vm.warp(block.timestamp + DAY);
        uint64 second = epoch();
        allocate(second, 500_000_000, CAP);
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](5);
        for (uint256 i; i < 5; ++i) payments[i] = payment(i, provider, MAX_REWARD);
        batch(first, payments);
        assertEq(vault.periodSpent(second), CAP);
        vm.expectRevert(MetrionEpochRewards.PayoutDayCapExceeded.selector);
        pay(second, 6, referrer, 500_000);
        assertFalse(vault.paidContributions(contribution(6)));
        assertEq(vault.totalReserved(), CAP);
        vm.warp(block.timestamp + DAY);
        pay(second, 6, referrer, 500_000);
        assertEq(vault.periodSpent(second), CAP);
        assertEq(vault.periodSpent(epoch()), 500_000);
        assertEq(vault.totalPaid(), CAP + 500_000);
    }

    function test_loweringOrRaisingDailyCapCannotResetActualPayoutHistory() public {
        allocate(epoch(), 500_000_000, CAP);
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](3);
        for (uint256 i; i < 3; ++i) payments[i] = payment(i, provider, MAX_REWARD);
        batch(epoch(), payments);
        vault.setPolicy(2_000_000, MAX_REWARD, 100);
        vm.expectRevert(MetrionEpochRewards.PayoutDayCapExceeded.selector);
        pay(epoch(), 4, referrer, 1);
        vault.setPolicy(3_100_000, MAX_REWARD, 100);
        pay(epoch(), 4, referrer, 100_000);
        assertEq(vault.periodSpent(epoch()), 3_100_000);
        vm.expectRevert(MetrionEpochRewards.PayoutDayCapExceeded.selector);
        pay(epoch(), 5, provider, 1);
        assertEq(vault.totalReserved(), 1_900_000);
        assertEq(vault.recipientPaid(provider), 3_000_000);
    }

    function test_zeroPercentageCannotTurnDepositIntoRewardBudget() public {
        vault.setPolicy(CAP, MAX_REWARD, 0);
        vm.expectRevert(MetrionEpochRewards.InvalidBudget.selector);
        allocate(epoch(), 1_000_000_000, 1);
        allocate(epoch(), 1_000_000_000, 0);
        assertEq(vault.totalReserved(), 0);
        assertEq(vault.availableToAllocate(), 50_000_000);
        vm.expectRevert(MetrionEpochRewards.EpochBudgetExceeded.selector);
        pay(epoch(), 1, provider, 1);
    }

    function test_onlyWorkerAllocatesAndPaysAndOnlyOwnerControlsPolicyOrWithdrawals() public {
        vm.prank(stranger);
        vm.expectRevert(MetrionEpochRewards.NotWorker.selector);
        vault.allocate(epoch(), 100_000_000, 1_000_000, FEES);
        vm.expectRevert(MetrionEpochRewards.NotWorker.selector);
        vault.allocate(epoch(), 100_000_000, 1_000_000, FEES);
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](1);
        payments[0] = payment(1, provider, 100_000);
        vm.prank(stranger);
        vm.expectRevert(MetrionEpochRewards.NotWorker.selector);
        vault.payBatch(epoch(), payments);
        address[2] memory callers = [worker, stranger];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(MetrionEpochRewards.NotOwner.selector);
            vault.setPolicy(CAP, MAX_REWARD, 200);
            vm.expectRevert(MetrionEpochRewards.NotOwner.selector);
            vault.pause(true);
            vm.expectRevert(MetrionEpochRewards.NotOwner.selector);
            vault.withdraw(1, callers[i]);
            vm.expectRevert(MetrionEpochRewards.NotOwner.selector);
            vault.withdrawUnallocated(callers[i]);
            vm.stopPrank();
        }
    }

    function test_pauseStopsNewAllocationsAndPaymentsAndResumePreservesCredit() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        vault.pause(true);
        vm.expectRevert(MetrionEpochRewards.RewardsPaused.selector);
        allocate(epoch(), 200_000_000, 2_000_000);
        vm.expectRevert(MetrionEpochRewards.RewardsPaused.selector);
        pay(epoch(), 1, provider, 100_000);
        vault.pause(false);
        pay(epoch(), 1, provider, 100_000);
        assertEq(vault.totalReserved(), 900_000);
    }

    function test_ownerCannotWithdrawCommittedUnpaidBudgets() public {
        allocate(epoch(), 100_000_000, 1_000_000);
        vm.expectRevert(MetrionEpochRewards.InsufficientFunding.selector);
        vault.withdraw(49_000_001, address(this));
        assertFalse(vault.paused());
        vault.withdrawUnallocated(address(this));
        assertTrue(vault.paused());
        assertEq(token.balanceOf(address(this)), 49_000_000);
        assertEq(token.balanceOf(address(vault)), 1_000_000);
        assertEq(vault.totalReserved(), 1_000_000);
        vault.pause(false);
        pay(epoch(), 1, provider, 1_000_000);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalReserved(), 0);
    }

    function test_invalidAndFailedWithdrawalsPreserveFundsAndPauseState() public {
        vm.expectRevert(MetrionEpochRewards.InvalidWithdrawal.selector);
        vault.withdraw(0, address(this));
        vm.expectRevert(MetrionEpochRewards.InvalidWithdrawal.selector);
        vault.withdraw(1, address(0));
        vm.expectRevert(MetrionEpochRewards.InvalidWithdrawal.selector);
        vault.withdrawUnallocated(address(vault));
        token.failTransfer(1);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, TOKEN));
        vault.withdrawUnallocated(address(this));
        assertFalse(vault.paused());
        assertEq(token.balanceOf(address(vault)), 50_000_000);
        token.failTransfer(0);
        vault.withdraw(100_000, address(this));
        assertTrue(vault.paused());
        assertEq(token.balanceOf(address(this)), 100_000);
    }

    function test_recipientHistoryHasNoLifetimeCapAndOldEpochCreditNeverExpires() public {
        uint64 first = epoch();
        for (uint256 i; i < 20; ++i) {
            vm.warp((uint256(first) + i) * DAY);
            allocate(epoch(), 100_000_000, 1_000_000);
            pay(epoch(), i, provider, 1_000_000);
        }
        assertEq(vault.recipientPaid(provider), 20_000_000);
        assertEq(vault.totalPaid(), 20_000_000);
        assertEq(vault.totalAllocated(), 20_000_000);
        assertEq(vault.totalReserved(), 0);
        allocate(epoch(), 200_000_000, 2_000_000);
        uint64 pending = epoch();
        vm.warp(block.timestamp + 1_000 days);
        pay(pending, 20, provider, 1_000_000);
        assertEq(vault.recipientPaid(provider), 21_000_000);
        assertTrue(vault.paidContributions(contribution(0)));
    }

    function test_tokenCallbackCannotReenterEvenAsAuthorizedWorker() public {
        MetrionEpochRewards guarded = new MetrionEpochRewards(TOKEN, CAP, MAX_REWARD, BPS, PILOT_CAP);
        token.mint(address(guarded), 1_000_000);
        token.callAsWorker(address(guarded), abi.encodeCall(MetrionEpochRewards.allocate, (epoch(), 100_000_000, 1_000_000, FEES)));
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](1);
        payments[0] = payment(2, referrer, 100_000);
        token.callback(address(guarded), abi.encodeCall(MetrionEpochRewards.payBatch, (epoch(), payments)));
        payments[0] = payment(1, provider, 100_000);
        token.callAsWorker(address(guarded), abi.encodeCall(MetrionEpochRewards.payBatch, (epoch(), payments)));
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(guarded.totalPaid(), 100_000);
        assertFalse(guarded.paidContributions(contribution(2)));
    }

    function testFuzz_budgetNeverExceedsFeeShareOrOwnerCap(uint64 fees, uint16 bps, uint64 target) public {
        fees = uint64(bound(fees, 1, 1_000_000_000_000));
        bps = uint16(bound(bps, 0, 1_000));
        vault.setPolicy(CAP, MAX_REWARD, bps);
        uint256 ceiling = uint256(fees) * bps / 10_000;
        if (ceiling > CAP) ceiling = CAP;
        target = uint64(bound(target, 0, CAP + 1));
        if (target > ceiling) {
            vm.expectRevert(MetrionEpochRewards.InvalidBudget.selector);
            allocate(epoch(), fees, target);
            assertEq(vault.totalReserved(), 0);
        } else {
            allocate(epoch(), fees, target);
            assertEq(vault.totalReserved(), target);
            assertLe(vault.totalAllocated(), ceiling);
        }
    }

    function testFuzz_batchPaymentsConserveAllEpochReservations(uint8 count, uint32 amount) public {
        count = uint8(bound(count, 1, 25));
        amount = uint32(bound(amount, 1, CAP / count));
        vault.setPolicy(CAP, CAP, BPS);
        allocate(epoch(), 500_000_000, CAP);
        MetrionEpochRewards.Payment[] memory payments = new MetrionEpochRewards.Payment[](count);
        for (uint256 i; i < count; ++i) payments[i] = payment(i, i % 2 == 0 ? provider : referrer, amount);
        batch(epoch(), payments);
        uint256 paid = uint256(count) * amount;
        assertEq(vault.totalPaid(), paid);
        assertEq(vault.totalReserved() + vault.totalPaid(), vault.totalAllocated());
        assertEq(token.balanceOf(address(vault)), 50_000_000 - paid);
        assertEq(token.balanceOf(provider) + token.balanceOf(referrer), paid);
        assertEq(vault.recipientPaid(provider) + vault.recipientPaid(referrer), paid);
    }

    function testFuzz_withdrawalCannotConsumeAnyReservedCredit(uint32 budget, uint32 requested) public {
        budget = uint32(bound(budget, 1, CAP));
        requested = uint32(bound(requested, 1, 50_000_001));
        allocate(epoch(), 500_000_000, budget);
        uint256 free = 50_000_000 - budget;
        if (requested > free) {
            vm.expectRevert(MetrionEpochRewards.InsufficientFunding.selector);
            vault.withdraw(requested, address(this));
        } else {
            vault.withdraw(requested, address(this));
        }
        assertGe(token.balanceOf(address(vault)), vault.totalReserved());
        assertEq(vault.totalReserved(), budget);
        assertEq(vault.totalPaid(), 0);
    }
}
