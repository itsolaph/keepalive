// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Keepalive} from "../Keepalive.sol";
import {ReentrantWithdrawer} from "../test-helpers/ReentrantWithdrawer.sol";
import {ReentrantSettleAndWithdrawer} from "../test-helpers/ReentrantSettleAndWithdrawer.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Shared fixture base
// ─────────────────────────────────────────────────────────────────────────────

abstract contract KeepaliveBase is Test {
    Keepalive internal ka;

    address internal provider  = makeAddr("provider");
    address internal signer    = makeAddr("signer");
    address internal alice     = makeAddr("alice");
    address internal bob       = makeAddr("bob");
    address internal stranger  = makeAddr("stranger");

    uint96  internal constant PRICE        = 1e18;   // 1 native token per epoch
    uint32  internal constant EPOCH_SECS   = 3600;   // 1 hour
    uint256 internal planId;

    function setUp() public virtual {
        ka = new Keepalive();

        // Fund users
        vm.deal(alice, 1_000_000e18);
        vm.deal(bob,   1_000_000e18);
        vm.deal(stranger, 1_000_000e18);

        // Create a standard plan
        vm.prank(provider);
        planId = ka.createPlan(PRICE, EPOCH_SECS, signer, "TestPlan");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// Advance time by N full epochs from plan start so currentEpoch() == N
    function _warpToEpoch(uint256 n) internal {
        (, , , uint64 startTime, ,) = ka.plans(planId);
        vm.warp(uint256(startTime) + n * EPOCH_SECS);
    }

    /// Heartbeat for the current epoch
    function _beat(uint256 pid) internal {
        vm.prank(signer);
        ka.heartbeat(pid);
    }

    /// Subscribe and return subId; msg.sender = caller, value = price * epochs
    function _subscribe(address caller, uint32 epochs) internal returns (uint256) {
        uint256 cost = uint256(PRICE) * uint256(epochs);
        vm.prank(caller);
        return ka.subscribe{value: cost}(planId, epochs);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  1. Deployment & plan creation
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveDeployTest is KeepaliveBase {

    function test_PlanCreatedCorrectly() public view {
        (
            address prov,
            uint96  price,
            uint32  epochSecs,
            uint64  startTime,
            address hbSigner,
            string memory name
        ) = ka.plans(planId);

        assertEq(prov,      provider,    "provider mismatch");
        assertEq(price,     PRICE,       "price mismatch");
        assertEq(epochSecs, EPOCH_SECS,  "epochSecs mismatch");
        assertEq(hbSigner,  signer,      "signer mismatch");
        assertEq(name,      "TestPlan",  "name mismatch");
        assertGt(startTime, 0,           "startTime should be set");
    }

    function test_PlanCountIncrements() public view {
        assertEq(ka.planCount(), 1);
    }

    function test_EmitsPlanCreated() public {
        vm.expectEmit(true, true, false, true, address(ka));
        emit Keepalive.PlanCreated(2, provider, PRICE, EPOCH_SECS, "Plan2");
        vm.prank(provider);
        ka.createPlan(PRICE, EPOCH_SECS, signer, "Plan2");
    }

    function test_CreatePlan_RevertInvalidEpochLength() public {
        vm.prank(provider);
        vm.expectRevert(Keepalive.InvalidEpochLength.selector);
        ka.createPlan(PRICE, 59, signer, "bad");
    }

    function test_CreatePlan_RevertInvalidPrice() public {
        vm.prank(provider);
        vm.expectRevert(Keepalive.InvalidPrice.selector);
        ka.createPlan(0, EPOCH_SECS, signer, "bad");
    }

    function test_CreatePlan_RevertInvalidSigner() public {
        vm.prank(provider);
        vm.expectRevert(Keepalive.InvalidSigner.selector);
        ka.createPlan(PRICE, EPOCH_SECS, address(0), "bad");
    }

    // v1.1: epochSeconds > 86400 reverts EpochTooLong()
    function test_CreatePlan_RevertEpochTooLong() public {
        vm.prank(provider);
        vm.expectRevert(Keepalive.EpochTooLong.selector);
        ka.createPlan(PRICE, 86401, signer, "too-long");
    }

    // v1.1: epochSeconds == 86400 is the exact boundary — succeeds
    function test_CreatePlan_EpochSeconds_MaxBoundary_Succeeds() public {
        vm.prank(provider);
        uint256 newPlanId = ka.createPlan(PRICE, 86400, signer, "max-epoch");
        assertEq(newPlanId, 2, "second plan should be id 2");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  2. Heartbeat
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveHeartbeatTest is KeepaliveBase {

    function test_SignerCanBeat() public {
        _warpToEpoch(1);
        uint256 epoch = ka.currentEpoch(planId);

        vm.prank(signer);
        ka.heartbeat(planId);

        assertTrue(ka.alive(planId, epoch), "epoch should be alive");
    }

    function test_Heartbeat_EmitsEvent() public {
        _warpToEpoch(1);
        uint256 epoch = ka.currentEpoch(planId);

        vm.expectEmit(true, true, false, true, address(ka));
        emit Keepalive.Heartbeat(planId, epoch, block.timestamp);
        vm.prank(signer);
        ka.heartbeat(planId);
    }

    function test_Heartbeat_RevertNotSigner() public {
        _warpToEpoch(1);
        vm.prank(stranger);
        vm.expectRevert(Keepalive.NotHeartbeatSigner.selector);
        ka.heartbeat(planId);
    }

    function test_Heartbeat_RevertProviderNotSigner() public {
        _warpToEpoch(1);
        vm.prank(provider);
        vm.expectRevert(Keepalive.NotHeartbeatSigner.selector);
        ka.heartbeat(planId);
    }

    /// Heartbeat cannot backfill a past epoch — only current epoch is settable.
    function test_Heartbeat_CannotBackfillPastEpoch() public {
        // Epoch 1: no heartbeat
        _warpToEpoch(1);
        // Epoch 2: beat — only epoch 2 gets marked, epoch 1 stays dead
        _warpToEpoch(2);
        _beat(planId);

        assertTrue(ka.alive(planId, 2), "epoch 2 should be alive");
        assertFalse(ka.alive(planId, 1), "epoch 1 should remain dead (no backfill)");
    }

    /// v1.1: Heartbeat is idempotent — second call in the same epoch does NOT emit.
    function test_Heartbeat_Idempotent_NoEmitOnSecondCall() public {
        _warpToEpoch(1);

        // First call — should emit Heartbeat
        vm.expectEmit(true, true, false, true, address(ka));
        emit Keepalive.Heartbeat(planId, 1, block.timestamp);
        vm.prank(signer);
        ka.heartbeat(planId);

        // Second call in the same epoch — alive already true, early return, NO emit.
        // We use vm.recordLogs() to confirm zero logs are emitted.
        vm.recordLogs();
        vm.prank(signer);
        ka.heartbeat(planId);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "second heartbeat in same epoch must not emit");

        assertTrue(ka.alive(planId, 1), "epoch still alive after second call");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  3. Subscribe
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveSubscribeTest is KeepaliveBase {

    function test_SubscribeHappyPath() public {
        _warpToEpoch(1);
        uint32 epochs = 3;
        uint256 cost  = uint256(PRICE) * epochs;

        vm.prank(alice);
        uint256 subId = ka.subscribe{value: cost}(planId, epochs);

        assertEq(subId, 1, "first subId should be 1");
        assertEq(ka.subCount(), 1);

        (
            uint256 pid,
            address subscriber,
            uint64 startEpoch,
            uint32 subEpochs,
            uint32 settled,
            bool cancelled
        ) = ka.subscriptions(subId);

        assertEq(pid,        planId);
        assertEq(subscriber, alice);
        assertEq(startEpoch, 2, "subscription starts on the NEXT epoch");
        assertEq(subEpochs,  epochs);
        assertEq(settled,    0);
        assertFalse(cancelled);
    }

    function test_Subscribe_EmitsEvent() public {
        _warpToEpoch(1);
        uint32 epochs = 2;
        uint256 cost  = uint256(PRICE) * epochs;

        vm.expectEmit(true, true, true, true, address(ka));
        emit Keepalive.Subscribed(1, planId, alice, 2, epochs);
        vm.prank(alice);
        ka.subscribe{value: cost}(planId, epochs);
    }

    function test_Subscribe_RevertWrongPaymentLow() public {
        _warpToEpoch(1);
        uint256 cost = uint256(PRICE) * 3;

        vm.prank(alice);
        vm.expectRevert(Keepalive.WrongPayment.selector);
        ka.subscribe{value: cost - 1}(planId, 3);
    }

    function test_Subscribe_RevertWrongPaymentHigh() public {
        _warpToEpoch(1);
        uint256 cost = uint256(PRICE) * 3;

        vm.prank(alice);
        vm.expectRevert(Keepalive.WrongPayment.selector);
        ka.subscribe{value: cost + 1}(planId, 3);
    }

    function test_Subscribe_RevertZeroEpochs() public {
        vm.prank(alice);
        vm.expectRevert(Keepalive.InvalidEpochCount.selector);
        ka.subscribe{value: 0}(planId, 0);
    }

    function test_Subscribe_RevertInvalidPlan() public {
        vm.prank(alice);
        vm.expectRevert(Keepalive.PlanNotFound.selector);
        ka.subscribe{value: PRICE}(999, 1);
    }

    function test_Subscribe_TracksInSubscriptionsOf() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 2);
        uint256[] memory subs = ka.subscriptionsOf(alice);
        assertEq(subs.length, 1);
        assertEq(subs[0], subId);
    }

    // v1.1: epochs > 10000 reverts TooManyEpochs()
    function test_Subscribe_RevertTooManyEpochs() public {
        _warpToEpoch(1);
        uint32 tooMany = 10001;
        uint256 cost = uint256(PRICE) * tooMany;
        vm.prank(alice);
        vm.expectRevert(Keepalive.TooManyEpochs.selector);
        ka.subscribe{value: cost}(planId, tooMany);
    }

    // v1.1: epochs == 10000 is the exact boundary — succeeds
    function test_Subscribe_MaxEpochs_Succeeds() public {
        // Use a cheap price so alice can afford 10000 epochs
        vm.prank(provider);
        uint256 cheapPlanId = ka.createPlan(1, EPOCH_SECS, signer, "cheap");

        _warpToEpoch(1);
        uint32 maxEpochs = 10000;
        uint256 cost = uint256(1) * uint256(maxEpochs); // 1 wei * 10000

        vm.prank(alice);
        uint256 subId = ka.subscribe{value: cost}(cheapPlanId, maxEpochs);

        (, , , uint32 storedEpochs, , ) = ka.subscriptions(subId);
        assertEq(storedEpochs, maxEpochs, "should store 10000 epochs");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  4. Settle — all alive (TC-1), all dead (TC-2), mixed (TC-3)
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveSettleTest is KeepaliveBase {

    /// TC-1: Happy path — all epochs alive → provider gets all payments
    function test_Settle_AllAlive_ProviderGetsAll() public {
        // Subscribe for 3 future epochs starting at epoch 2
        _warpToEpoch(1);
        uint32 epochs = 3;
        uint256 subId = _subscribe(alice, epochs);

        // Beat epochs 2, 3, 4
        _warpToEpoch(2); _beat(planId);
        _warpToEpoch(3); _beat(planId);
        _warpToEpoch(4); _beat(planId);

        // Advance one more epoch so all sub epochs are "ended"
        _warpToEpoch(5);

        vm.expectEmit(true, false, false, true, address(ka));
        emit Keepalive.Settled(subId, 3, 0);
        ka.settle(subId);

        assertEq(ka.credit(provider), uint256(PRICE) * 3, "provider should have full credit");
        assertEq(ka.credit(alice), 0, "alice should have no credit");
    }

    /// TC-2: Dead epochs — no heartbeat → subscriber gets full refund
    function test_Settle_AllDead_SubscriberGetsAll() public {
        _warpToEpoch(1);
        uint32 epochs = 3;
        uint256 subId = _subscribe(alice, epochs);

        // No heartbeats at epochs 2, 3, 4 — just advance time
        _warpToEpoch(5);

        vm.expectEmit(true, false, false, true, address(ka));
        emit Keepalive.Settled(subId, 0, 3);
        ka.settle(subId);

        assertEq(ka.credit(provider), 0,                  "provider should get nothing");
        assertEq(ka.credit(alice),    uint256(PRICE) * 3, "alice should get full refund");
    }

    /// TC-3: Mixed — some alive, some not → split correctly
    function test_Settle_Mixed_SplitCorrectly() public {
        _warpToEpoch(1);
        uint32 epochs = 4;
        uint256 subId = _subscribe(alice, epochs);

        // Subscription epochs: 2, 3, 4, 5
        // Beat epochs 2 and 4; leave 3 and 5 dead
        _warpToEpoch(2); _beat(planId);
        _warpToEpoch(3); // no beat
        _warpToEpoch(4); _beat(planId);
        _warpToEpoch(5); // no beat
        _warpToEpoch(6); // advance past end

        vm.expectEmit(true, false, false, true, address(ka));
        emit Keepalive.Settled(subId, 2, 2);
        ka.settle(subId);

        assertEq(ka.credit(provider), uint256(PRICE) * 2, "provider: 2 alive epochs");
        assertEq(ka.credit(alice),    uint256(PRICE) * 2, "alice: 2 dead epochs refunded");
    }

    /// v1.1: Double-settle is a no-op — second call emits NOTHING (paidEpochs==0, refundedEpochs==0
    /// means settledNow==0 so Settled is NOT emitted).
    function test_Settle_DoubleSettleIsNoop() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 2);

        _warpToEpoch(2); _beat(planId);
        _warpToEpoch(3); // no beat
        _warpToEpoch(4); // past end

        // First settle
        ka.settle(subId);
        uint256 providerCreditAfterFirst = ka.credit(provider);
        uint256 aliceCreditAfterFirst    = ka.credit(alice);

        // Second settle — must be a complete no-op: no emit, no state change.
        vm.recordLogs();
        ka.settle(subId);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "second settle must not emit any event");

        assertEq(ka.credit(provider), providerCreditAfterFirst, "provider credit unchanged on double-settle");
        assertEq(ka.credit(alice),    aliceCreditAfterFirst,    "alice credit unchanged on double-settle");
    }

    /// v1.1: Settle before any epochs end → no-op — settle() emits NOTHING
    /// (paidEpochs==0 && refundedEpochs==0 → settledNow==0 → no Settled emit).
    function test_Settle_BeforeAnyEpochEnded_IsNoop() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 3); // epochs 2, 3, 4

        // Still in epoch 1 — subscription hasn't started yet
        vm.recordLogs();
        ka.settle(subId);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no emit when nothing settled");

        assertEq(ka.credit(provider), 0);
        assertEq(ka.credit(alice),    0);
    }

    /// v1.1: _getSubscription reverts with SubscriptionNotFound() for an invalid subId.
    function test_Settle_RevertSubscriptionNotFound() public {
        vm.expectRevert(Keepalive.SubscriptionNotFound.selector);
        ka.settle(9999);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  5. Cancel
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveCancelTest is KeepaliveBase {

    /// TC-4: Cancel mid-way — ended epochs settle normally, future epochs refunded
    function test_Cancel_MidwaySettlesEndedRefundsFuture() public {
        _warpToEpoch(1);
        uint32 epochs = 5;
        uint256 subId = _subscribe(alice, epochs);
        // Subscription covers epochs 2..6

        // Beat epoch 2, skip 3
        _warpToEpoch(2); _beat(planId);
        _warpToEpoch(3); // no beat

        // Cancel in epoch 4: epochs 2 & 3 have ended; epoch 4 is current;
        // epochs 5 & 6 are future.
        _warpToEpoch(4);
        vm.prank(alice);
        ka.cancel(subId);

        // _settleEnded: epoch 2 alive→provider, epoch 3 dead→alice
        // cancel: firstFuture = 5, refundableEpochs = 6-5+1 = 2 → alice
        assertEq(ka.credit(provider), uint256(PRICE) * 1, "provider: 1 alive ended epoch");
        assertEq(ka.credit(alice),    uint256(PRICE) * 3, "alice: dead epoch + future epochs 5,6");

        (, , , , , bool cancelled) = ka.subscriptions(subId);
        assertTrue(cancelled, "subscription should be cancelled");
    }

    /// v1.1: Cancelled event now has two args: (subId, refundedFuture)
    function test_Cancel_EmitsCancelled() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 3);
        // Warp to epoch 5 — all 3 subscription epochs (2,3,4) have ended, none future.
        _warpToEpoch(5);

        // refundedFuture == 0 because endEpoch (4) <= current (5), no future refund.
        vm.expectEmit(true, false, false, true, address(ka));
        emit Keepalive.Cancelled(subId, 0);
        vm.prank(alice);
        ka.cancel(subId);
    }

    /// v1.1: Cancelled event with non-zero refundedFuture
    function test_Cancel_EmitsCancelled_WithFutureRefund() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 5); // epochs 2..6

        _warpToEpoch(4); // cancel during epoch 4; future = epochs 5 & 6 → 2 * PRICE
        // refundedFuture = 2 * PRICE
        vm.expectEmit(true, false, false, true, address(ka));
        emit Keepalive.Cancelled(subId, 2 * uint256(PRICE));
        vm.prank(alice);
        ka.cancel(subId);
    }

    function test_Cancel_RevertNotSubscriber() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 3);

        vm.prank(stranger);
        vm.expectRevert(Keepalive.NotSubscriber.selector);
        ka.cancel(subId);
    }

    function test_Cancel_RevertAlreadyCancelled() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 3);

        vm.prank(alice);
        ka.cancel(subId);

        vm.prank(alice);
        vm.expectRevert(Keepalive.AlreadyCancelled.selector);
        ka.cancel(subId);
    }

    /// Cancel before subscription's first epoch starts → full refund to subscriber
    function test_Cancel_BeforeStartGivesFullRefund() public {
        _warpToEpoch(0); // epoch 0, sub will start at epoch 1
        uint32 epochs = 4;
        uint256 subId = _subscribe(alice, epochs);
        // Still in epoch 0 — no epochs have started
        // Cancel immediately, all 4 future epochs refunded
        vm.prank(alice);
        ka.cancel(subId);

        assertEq(ka.credit(alice), uint256(PRICE) * epochs, "full refund expected");
        assertEq(ka.credit(provider), 0, "provider gets nothing");
    }

    // v1.1: cancel on invalid subId reverts SubscriptionNotFound()
    function test_Cancel_RevertSubscriptionNotFound() public {
        vm.prank(alice);
        vm.expectRevert(Keepalive.SubscriptionNotFound.selector);
        ka.cancel(9999);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  6. Withdraw
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveWithdrawTest is KeepaliveBase {

    function test_Withdraw_TransfersCreditToSender() public {
        // Give alice some credit by having a dead epoch settle
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 1); // epoch 2
        _warpToEpoch(3); // epoch 2 ended, no heartbeat

        ka.settle(subId);
        assertEq(ka.credit(alice), PRICE);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        ka.withdraw();

        assertEq(alice.balance,    balBefore + PRICE, "alice should receive credit");
        assertEq(ka.credit(alice), 0,                 "credit should be zeroed");
    }

    function test_Withdraw_EmitsWithdrawn() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 1);
        _warpToEpoch(3);
        ka.settle(subId);

        vm.expectEmit(true, false, false, true, address(ka));
        emit Keepalive.Withdrawn(alice, PRICE);
        vm.prank(alice);
        ka.withdraw();
    }

    function test_Withdraw_ZeroCredit_NoTransfer() public {
        // Alice has no credit; withdraw should succeed (sends 0) without revert
        vm.prank(alice);
        ka.withdraw();
        assertEq(ka.credit(alice), 0);
    }

    /// TC-9: Reentrancy on withdraw — malicious contract re-enters and should be blocked.
    function test_Withdraw_ReentrantAttackFails() public {
        // Deploy the attacker
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(ka);
        vm.deal(address(attacker), 100e18);

        // Attacker subscribes to get funds locked in the contract
        _warpToEpoch(1);
        vm.prank(address(attacker));
        uint256 subId = ka.subscribe{value: PRICE * 2}(planId, 2);

        // Advance past subscription end — no heartbeats → all refunded to subscriber (attacker)
        _warpToEpoch(5);
        ka.settle(subId); // credit[attacker] = 2 * PRICE

        assertEq(ka.credit(address(attacker)), PRICE * 2, "attacker should have credit before attack");

        // The re-entry attack: outer withdraw() reverts with WithdrawFailed() because
        // the inner withdraw() (triggered from receive()) reverts with Reentrancy(),
        // which propagates back through the ETH transfer making ok=false.
        vm.expectRevert(Keepalive.WithdrawFailed.selector);
        attacker.attack();

        // Credit must remain intact — the whole tx reverted
        assertEq(ka.credit(address(attacker)), PRICE * 2, "credit must remain intact after failed re-entry");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  7. settleAndWithdraw
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveSettleAndWithdrawTest is KeepaliveBase {

    /// Happy path: settle two subscriptions and withdraw in one call
    function test_SettleAndWithdraw_HappyPath() public {
        _warpToEpoch(1);

        // alice subscribes to two separate subs on the same plan
        uint256 subId1 = _subscribe(alice, 2); // epochs 2, 3
        uint256 subId2 = _subscribe(alice, 2); // epochs 2, 3

        // Beat epochs 2 and 3
        _warpToEpoch(2); _beat(planId);
        _warpToEpoch(3); _beat(planId);
        _warpToEpoch(4); // past end, both subs fully ended

        uint256 balBefore = alice.balance;

        uint256[] memory ids = new uint256[](2);
        ids[0] = subId1;
        ids[1] = subId2;

        // Provider credit should now be 4 * PRICE (2 epochs * 2 subs)
        vm.prank(alice);
        ka.settleAndWithdraw(ids);

        // Alice had no dead epochs, so credit = 0 → transfer = 0
        assertEq(alice.balance, balBefore, "alice: no dead epochs, no refund");
        // Provider credit: 4 * PRICE (stays as credit, not withdrawn by alice)
        assertEq(ka.credit(provider), uint256(PRICE) * 4, "provider: 4 alive epochs");
    }

    /// Happy path with dead epochs — alice gets refund on settleAndWithdraw
    function test_SettleAndWithdraw_DeadEpochs_SubscriberWithdraws() public {
        _warpToEpoch(1);

        uint256 subId1 = _subscribe(alice, 2); // epochs 2, 3 — no heartbeat
        uint256 subId2 = _subscribe(alice, 2); // epochs 2, 3 — no heartbeat

        _warpToEpoch(4); // past end, no beats

        uint256 balBefore = alice.balance;

        uint256[] memory ids = new uint256[](2);
        ids[0] = subId1;
        ids[1] = subId2;

        vm.prank(alice);
        ka.settleAndWithdraw(ids);

        // Both subs refunded: 4 * PRICE
        assertEq(alice.balance, balBefore + uint256(PRICE) * 4, "alice should receive 4 epoch refunds");
        assertEq(ka.credit(alice), 0, "alice credit drained after settleAndWithdraw");
    }

    /// TooManyIds: pass 21 subIds → reverts TooManyIds()
    function test_SettleAndWithdraw_RevertTooManyIds() public {
        uint256[] memory ids = new uint256[](21);
        vm.prank(alice);
        vm.expectRevert(Keepalive.TooManyIds.selector);
        ka.settleAndWithdraw(ids);
    }

    /// Skip fully settled: one sub fully settled, one unsettled
    function test_SettleAndWithdraw_SkipsFullySettled() public {
        _warpToEpoch(1);

        uint256 subId1 = _subscribe(alice, 1); // epoch 2 — will be pre-settled
        uint256 subId2 = _subscribe(alice, 1); // epoch 2 — will not be pre-settled

        _warpToEpoch(3); // both ended, no beats
        ka.settle(subId1); // pre-settle subId1

        // Only subId2 should be settled by settleAndWithdraw
        uint256 balBefore = alice.balance;
        uint256[] memory ids = new uint256[](2);
        ids[0] = subId1;
        ids[1] = subId2;

        vm.prank(alice);
        ka.settleAndWithdraw(ids);

        // alice gets 2 * PRICE (1 from pre-settle + 1 from settleAndWithdraw now)
        assertEq(alice.balance, balBefore + uint256(PRICE) * 2, "alice: 2 dead epoch refunds");
    }

    /// Zero credit: call settleAndWithdraw on fully settled subs — succeeds without transferring
    function test_SettleAndWithdraw_ZeroCredit_Succeeds() public {
        _warpToEpoch(1);
        uint256 subId1 = _subscribe(alice, 1); // epoch 2
        _warpToEpoch(2); _beat(planId); // alive
        _warpToEpoch(3); // ended

        // Pre-settle — provider gets credit, alice gets nothing
        ka.settle(subId1);
        assertEq(ka.credit(alice), 0, "no credit before settleAndWithdraw");

        uint256[] memory ids = new uint256[](1);
        ids[0] = subId1;

        // Should succeed with no transfer (zero credit)
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        ka.settleAndWithdraw(ids); // no revert, no transfer
        assertEq(alice.balance, balBefore, "no ETH transferred for zero credit");
    }

    /// Reentrancy on settleAndWithdraw: malicious contract re-enters → Reentrancy() revert
    function test_SettleAndWithdraw_ReentrantAttackFails() public {
        ReentrantSettleAndWithdrawer attacker = new ReentrantSettleAndWithdrawer(ka);
        vm.deal(address(attacker), 100e18);

        _warpToEpoch(1);

        // Attacker subscribes for 2 epochs
        vm.prank(address(attacker));
        uint256 subId = ka.subscribe{value: PRICE * 2}(planId, 2);

        // Advance past subscription end — no heartbeats → all refunded
        _warpToEpoch(5);
        ka.settle(subId);

        assertEq(ka.credit(address(attacker)), PRICE * 2, "attacker should have credit before attack");

        uint256[] memory ids = new uint256[](1);
        ids[0] = subId;

        // Reentrant attack: inner settleAndWithdraw triggers Reentrancy(), outer reverts WithdrawFailed()
        vm.expectRevert(Keepalive.WithdrawFailed.selector);
        attacker.attack(ids);

        // Credit must remain intact — tx reverted
        assertEq(ka.credit(address(attacker)), PRICE * 2, "credit must remain after failed re-entry");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  8. subscriptionState
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveSubscriptionStateTest is KeepaliveBase {

    /// Before any epoch ends: escrowed = full price * epochs, pending = 0, 0
    function test_SubscriptionState_BeforeAnyEpochEnds() public {
        _warpToEpoch(1);
        uint32 epochs = 3;
        uint256 subId = _subscribe(alice, epochs); // epochs 2, 3, 4

        // Still in epoch 1 — no sub epoch has ended yet
        (uint256 escrowed, uint256 pendingToProvider, uint256 pendingToSubscriber) = ka.subscriptionState(subId);

        assertEq(escrowed,           uint256(PRICE) * epochs, "all funds still escrowed");
        assertEq(pendingToProvider,   0, "nothing pending to provider yet");
        assertEq(pendingToSubscriber, 0, "nothing pending to subscriber yet");
    }

    /// After some alive epochs end (unsettled): pendingToProvider > 0, escrowed reduced
    function test_SubscriptionState_AfterAliveEpochsEnd_Unsettled() public {
        _warpToEpoch(1);
        uint32 epochs = 3;
        uint256 subId = _subscribe(alice, epochs); // epochs 2, 3, 4

        // Beat epoch 2 and advance past it
        _warpToEpoch(2); _beat(planId);
        _warpToEpoch(3); // epoch 2 ended, epoch 3 is current

        // No settle called yet — epoch 2 is ended & alive, pending to provider
        (uint256 escrowed, uint256 pendingToProvider, uint256 pendingToSubscriber) = ka.subscriptionState(subId);

        // pendingToProvider should be 1 * PRICE (epoch 2 alive, ended)
        assertEq(pendingToProvider,   uint256(PRICE), "epoch 2 alive: pending to provider");
        assertEq(pendingToSubscriber, 0,              "no dead epochs yet");
        // escrowed = total_locked - pending: total = 3*PRICE, unsettled=3, pending=PRICE → escrowed=2*PRICE
        assertEq(escrowed, uint256(PRICE) * 2, "escrowed reduced by pending");
    }

    /// After settle: escrowed and pending both reduced
    function test_SubscriptionState_AfterSettle() public {
        _warpToEpoch(1);
        uint32 epochs = 3;
        uint256 subId = _subscribe(alice, epochs); // epochs 2, 3, 4

        // Beat epoch 2
        _warpToEpoch(2); _beat(planId);
        _warpToEpoch(3); // epoch 2 ended

        ka.settle(subId); // settles epoch 2

        (uint256 escrowed, uint256 pendingToProvider, uint256 pendingToSubscriber) = ka.subscriptionState(subId);

        // After settle of epoch 2: settledCount=1, unsettled=2 (epochs 3,4 not ended yet)
        // pending: epochs 3,4 not ended → both 0
        assertEq(pendingToProvider,   0, "epoch 2 already settled");
        assertEq(pendingToSubscriber, 0, "no unsettled dead epochs");
        // escrowed = total_locked - pending = 2*PRICE - 0 = 2*PRICE
        assertEq(escrowed, uint256(PRICE) * 2, "2 unsettled epochs remain escrowed");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  9. pending() view
// ═════════════════════════════════════════════════════════════════════════════

contract KeepalivePendingTest is KeepaliveBase {

    function test_Pending_AllAlive() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 2); // epochs 2, 3

        _warpToEpoch(2); _beat(planId);
        _warpToEpoch(3); _beat(planId);
        _warpToEpoch(4); // past end

        (uint256 toProvider, uint256 toSubscriber) = ka.pending(subId);
        assertEq(toProvider,    uint256(PRICE) * 2);
        assertEq(toSubscriber,  0);
    }

    function test_Pending_AllDead() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 2);
        _warpToEpoch(4);

        (uint256 toProvider, uint256 toSubscriber) = ka.pending(subId);
        assertEq(toProvider,   0);
        assertEq(toSubscriber, uint256(PRICE) * 2);
    }

    function test_Pending_AfterFullSettle_IsZero() public {
        _warpToEpoch(1);
        uint256 subId = _subscribe(alice, 2);
        _warpToEpoch(4);
        ka.settle(subId);

        (uint256 toProvider, uint256 toSubscriber) = ka.pending(subId);
        assertEq(toProvider,   0);
        assertEq(toSubscriber, 0);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  10. currentEpoch view
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveCurrentEpochTest is KeepaliveBase {

    function test_CurrentEpoch_AtPlanStart_IsZero() public view {
        assertEq(ka.currentEpoch(planId), 0);
    }

    function test_CurrentEpoch_AfterOneEpoch_IsOne() public {
        _warpToEpoch(1);
        assertEq(ka.currentEpoch(planId), 1);
    }

    function test_CurrentEpoch_RevertInvalidPlan() public {
        vm.expectRevert(Keepalive.PlanNotFound.selector);
        ka.currentEpoch(999);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  11. Regression: bounded cancel with >256 ended epochs
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveBoundedCancelTest is KeepaliveBase {

    // Use a separate plan with epochSeconds = 60 and low price to keep arithmetic manageable
    uint256 internal shortPlanId;
    address internal shortSigner = makeAddr("shortSigner");
    uint96  internal constant SHORT_PRICE = 1e15; // 0.001 ETH per epoch
    uint32  internal constant SHORT_EPOCH = 60;   // 60 seconds

    function setUp() public override {
        super.setUp();
        vm.prank(provider);
        shortPlanId = ka.createPlan(SHORT_PRICE, SHORT_EPOCH, shortSigner, "ShortPlan");
    }

    function _warpToShortEpoch(uint256 n) internal {
        (, , , uint64 startTime, ,) = ka.plans(shortPlanId);
        vm.warp(uint256(startTime) + n * SHORT_EPOCH);
    }

    function _beatShort(uint256 epoch) internal {
        // warp to that epoch's interior, beat, then return to the test's current time
        (, , , uint64 startTime, ,) = ka.plans(shortPlanId);
        uint256 target = uint256(startTime) + epoch * SHORT_EPOCH + 1;
        vm.warp(target);
        vm.prank(shortSigner);
        ka.heartbeat(shortPlanId);
    }

    function test_BoundedCancel_MoreThan256EndedEpochs() public {
        // ── Setup ─────────────────────────────────────────────────────────────
        // Subscribe for 300 epochs starting at epoch 1 (subscribe during epoch 0).
        // Subscription covers epochs 1..300 (startEpoch=1, epochs=300).
        _warpToShortEpoch(0);
        uint32 totalEpochs = 300;
        uint256 cost = uint256(SHORT_PRICE) * totalEpochs;
        vm.prank(alice);
        uint256 subId = ka.subscribe{value: cost}(shortPlanId, totalEpochs);

        // Beat epochs 1..260 (only these; epoch 261 will be left dead).
        for (uint256 ep = 1; ep <= 260; ep++) {
            _beatShort(ep);
        }

        // ── Cancel in epoch 261 ───────────────────────────────────────────────
        // Warp to epoch 261 → currentEpoch = 261, lastEnded = 260.
        // cancel() calls _settleEnded(cap=256):
        //   settledNow = min(260-1+1, 256) = 256  →  settles epochs 1..256 (all alive)
        //   settledCount → 256
        // Then cancel computes future refund:
        //   firstFuture = 261 + 1 = 262
        //   refundableEpochs = 300 - 262 + 1 = 39
        //   credit[alice] += 39 * SHORT_PRICE
        //   sub.epochs = keptEpochs = firstFuture - startEpoch = 262 - 1 = 261
        //     (sub now covers epochs 1..261; epoch 261 is current/dead)
        _warpToShortEpoch(261);

        uint256 providerCreditBefore = ka.credit(provider);

        vm.prank(alice);
        ka.cancel(subId);

        // Immediately after cancel:
        //   provider credit: +256 * SHORT_PRICE (epochs 1..256 alive, settled by _settleEnded)
        //   alice credit:    +39  * SHORT_PRICE (future epochs 262..300 refunded)
        assertEq(
            ka.credit(provider),
            providerCreditBefore + 256 * uint256(SHORT_PRICE),
            "provider: 256 alive epochs settled on cancel"
        );
        assertEq(
            ka.credit(alice),
            39 * uint256(SHORT_PRICE),
            "alice: 39 future epochs (262..300) refunded on cancel"
        );

        // Contract still holds the full original deposit (credits + unsettled locked):
        //   Locked:   (261 - 256) * SHORT_PRICE = 5 epochs (257..261, unsettled)
        //   Credits:  256 (provider) + 39 (alice) = 295 epochs
        //   Total:    5 + 295 = 300 * SHORT_PRICE ✓
        assertEq(
            address(ka).balance,
            uint256(totalEpochs) * uint256(SHORT_PRICE),
            "contract holds full original deposit"
        );

        // ── First settle: resolves 4 capped ended epochs (257..260) ──────────
        // Still in epoch 261, so lastEnded = 260.
        // nextEpoch = startEpoch + settledCount = 1 + 256 = 257.
        // settledNow = min(260-257+1, 256) = 4  →  epochs 257..260 (all alive).
        ka.settle(subId);

        assertEq(
            ka.credit(provider),
            providerCreditBefore + 260 * uint256(SHORT_PRICE),
            "provider: 260 alive epochs total (1..260)"
        );
        // alice: still 39 * SHORT_PRICE — no change from this settle
        assertEq(
            ka.credit(alice),
            39 * uint256(SHORT_PRICE),
            "alice: future refund unchanged after first settle"
        );

        // ── Second settle: resolves epoch 261 (dead → subscriber) ────────────
        // Warp to epoch 262 so epoch 261 has ended.
        // nextEpoch = 1 + 260 = 261. lastEnded = 261. settledNow = 1.
        // alive[shortPlanId][261] == false  →  credit[alice] += SHORT_PRICE
        _warpToShortEpoch(262);
        ka.settle(subId);

        // sub.epochs=261, settledCount=261 → fully settled
        // epoch 261 is dead → alice gets it
        assertEq(
            ka.credit(provider),
            providerCreditBefore + 260 * uint256(SHORT_PRICE),
            "provider: 260 alive epochs (unchanged - epoch 261 was dead)"
        );
        assertEq(
            ka.credit(alice),
            40 * uint256(SHORT_PRICE),
            "alice: 39 future + 1 dead epoch-261 = 40 * SHORT_PRICE"
        );

        // ── Final conservation check ──────────────────────────────────────────
        // 260 (provider) + 40 (alice) = 300 * SHORT_PRICE = original deposit
        assertEq(
            ka.credit(provider) + ka.credit(alice),
            uint256(totalEpochs) * uint256(SHORT_PRICE),
            "total credits == original deposit"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  12. Fuzz: pricePerEpoch and epochs — msg.value calculation and credits
// ═════════════════════════════════════════════════════════════════════════════

contract KeepaliveFuzzTest is KeepaliveBase {

    /// Fuzz pricePerEpoch and epochs; verify msg.value = price * epochs and credits
    function testFuzz_SubscribeValueAndCredits(
        uint96 price,
        uint32 epochs
    ) public {
        // Constrain to valid domain — prices non-zero, epochs non-zero, epochs <= 10000
        price  = uint96(bound(uint256(price),  1, 1e20));    // 1 wei to 100 tokens
        epochs = uint32(bound(uint256(epochs), 1, 50));      // up to 50 epochs

        // Create a new plan with fuzzed price
        address fuzzSigner   = makeAddr("fuzzSigner");
        address fuzzProvider = makeAddr("fuzzProvider");
        vm.prank(fuzzProvider);
        uint256 fuzzPlanId = ka.createPlan(price, EPOCH_SECS, fuzzSigner, "FuzzPlan");

        (, , , uint64 startTime, , ) = ka.plans(fuzzPlanId);

        // Fund alice with exactly the required amount
        uint256 cost = uint256(price) * uint256(epochs);
        vm.deal(alice, cost);

        // Move 1 epoch forward so subscription starts at epoch 2
        vm.warp(uint256(startTime) + EPOCH_SECS);

        vm.prank(alice);
        uint256 subId = ka.subscribe{value: cost}(fuzzPlanId, epochs);

        // Confirm subscription stored correctly
        (, , uint64 startEpoch, uint32 storedEpochs, , ) = ka.subscriptions(subId);
        assertEq(storedEpochs, epochs, "stored epochs should match");
        assertEq(startEpoch,   2,      "start epoch should be 2");

        // Advance past all subscription epochs with all heartbeats fired
        (, , , uint64 pst, , ) = ka.plans(fuzzPlanId);
        vm.warp(uint256(pst) + (uint256(startEpoch) + uint256(epochs)) * uint256(EPOCH_SECS));

        // Beat every epoch in the subscription window
        for (uint32 i = 0; i < epochs; i++) {
            uint256 ep = uint256(startEpoch) + uint256(i);
            vm.warp(uint256(pst) + ep * uint256(EPOCH_SECS) + 1);
            vm.prank(fuzzSigner);
            ka.heartbeat(fuzzPlanId);
        }

        // Advance past the last subscription epoch
        vm.warp(uint256(pst) + (uint256(startEpoch) + uint256(epochs)) * uint256(EPOCH_SECS) + 1);

        ka.settle(subId);

        // PROPERTY: provider credit == price * epochs (all alive)
        assertEq(ka.credit(fuzzProvider), cost, "provider credit should equal total payment");
        assertEq(ka.credit(alice),        0,    "alice credit should be zero (all epochs alive)");
    }

    /// Fuzz: wrong payment always reverts
    function testFuzz_WrongPaymentAlwaysReverts(uint96 price, uint32 epochs, uint256 wrongValue) public {
        price  = uint96(bound(uint256(price),  1, 1e20));
        epochs = uint32(bound(uint256(epochs), 1, 50));

        uint256 correct = uint256(price) * uint256(epochs);
        vm.assume(wrongValue != correct);
        wrongValue = bound(wrongValue, 0, correct + 1e30);

        address fuzzSigner   = makeAddr("fz2Signer");
        address fuzzProvider = makeAddr("fz2Provider");
        vm.prank(fuzzProvider);
        uint256 fuzzPlanId = ka.createPlan(price, EPOCH_SECS, fuzzSigner, "FP2");

        vm.deal(alice, wrongValue);
        vm.prank(alice);
        vm.expectRevert(Keepalive.WrongPayment.selector);
        ka.subscribe{value: wrongValue}(fuzzPlanId, epochs);
    }

    /// Fuzz: credit conservation — all-dead subscription → subscriber gets full refund
    function testFuzz_AllDeadFullRefund(uint96 price, uint32 epochs) public {
        price  = uint96(bound(uint256(price),  1, 1e20));
        epochs = uint32(bound(uint256(epochs), 1, 30));

        address fuzzSigner   = makeAddr("fd3Signer");
        address fuzzProvider = makeAddr("fd3Provider");
        vm.prank(fuzzProvider);
        uint256 fuzzPlanId = ka.createPlan(price, EPOCH_SECS, fuzzSigner, "FP3");

        uint256 cost = uint256(price) * uint256(epochs);
        vm.deal(alice, cost);

        (, , , uint64 pst, , ) = ka.plans(fuzzPlanId);
        vm.warp(uint256(pst) + EPOCH_SECS); // epoch 1

        vm.prank(alice);
        uint256 subId = ka.subscribe{value: cost}(fuzzPlanId, epochs);

        // Advance past all epochs, no beats
        (, , uint64 startEpoch, , , ) = ka.subscriptions(subId);
        vm.warp(uint256(pst) + (uint256(startEpoch) + uint256(epochs)) * uint256(EPOCH_SECS) + 1);

        ka.settle(subId);

        // PROPERTY: subscriber gets full refund, provider gets nothing
        assertEq(ka.credit(alice),        cost, "subscriber should get full refund");
        assertEq(ka.credit(fuzzProvider), 0,    "provider should get nothing");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  13. Invariant: contract balance == sum(credits) + sum(locked subscription funds)
// ═════════════════════════════════════════════════════════════════════════════

/// @dev Handler for invariant testing. Tracks all actors and ghost sums.
contract KeepaliveHandler is Test {
    Keepalive public ka;
    uint256   public planId;
    address   public signerAddr;

    // Actors used by the handler
    address[] internal actors;
    uint256[] internal subIds;

    // Ghost accounting — tracks expected balance breakdown
    uint256 public ghostLockedFunds;      // funds locked in active (not-fully-settled) subs
    uint256 public ghostTotalCredits;     // sum of all credit[] entries

    uint96  public constant PRICE      = 1e18;
    uint32  public constant EPOCH_SECS = 3600;

    constructor(Keepalive _ka, uint256 _planId, address _signer) {
        ka        = _ka;
        planId    = _planId;
        signerAddr = _signer;

        // Pre-fund actors
        for (uint256 i = 0; i < 3; i++) {
            address a = address(uint160(0xBEEF0001 + i));
            vm.deal(a, 1_000_000e18);
            actors.push(a);
        }
    }

    function subscribe(uint256 actorSeed, uint32 epochs) external {
        epochs = uint32(bound(uint256(epochs), 1, 10));
        address actor = actors[actorSeed % actors.length];

        uint256 cost = uint256(PRICE) * uint256(epochs);
        vm.deal(actor, actor.balance + cost);

        vm.prank(actor);
        uint256 subId = ka.subscribe{value: cost}(planId, epochs);
        subIds.push(subId);

        ghostLockedFunds += cost;
    }

    function heartbeat() external {
        vm.prank(signerAddr);
        try ka.heartbeat(planId) {} catch {}
    }

    function settle(uint256 subIdSeed) external {
        if (subIds.length == 0) return;
        uint256 subId = subIds[subIdSeed % subIds.length];

        (, , , uint32 subEpochs, uint32 settledCount, ) = ka.subscriptions(subId);
        uint256 unsettledBefore = subEpochs > settledCount ? subEpochs - settledCount : 0;
        if (unsettledBefore == 0) return;

        (, uint256 planIdStored, , , , ) = _getSubData(subId);
        (address provAddr,,,,,) = _getPlanData(planIdStored);

        uint256 provBefore = ka.credit(provAddr);
        uint256 subBefore  = _getSubscriberCredit(subId);

        ka.settle(subId);

        uint256 provDelta = ka.credit(provAddr) - provBefore;
        uint256 subDelta  = _getSubscriberCredit(subId) - subBefore;

        // Update ghost accounting
        uint256 fundsReleased = provDelta + subDelta;
        if (fundsReleased <= ghostLockedFunds) {
            ghostLockedFunds  -= fundsReleased;
        }
        ghostTotalCredits += fundsReleased;
    }

    function cancelSub(uint256 subIdSeed) external {
        if (subIds.length == 0) return;
        uint256 subId = subIds[subIdSeed % subIds.length];

        (, address subscriber, , , , bool cancelled) =
            _getSubDataFull(subId);

        if (cancelled) return;

        uint256 subBefore  = ka.credit(subscriber);
        (, uint256 pid, , , , ) = _getSubData(subId);
        (address provAddr,,,,,) = _getPlanData(pid);
        uint256 provBefore = ka.credit(provAddr);

        vm.prank(subscriber);
        try ka.cancel(subId) {
            uint256 subDelta  = ka.credit(subscriber) - subBefore;
            uint256 provDelta = ka.credit(provAddr)   - provBefore;
            uint256 released  = subDelta + provDelta;
            if (released <= ghostLockedFunds) {
                ghostLockedFunds  -= released;
            }
            ghostTotalCredits += released;
        } catch {}
    }

    function withdraw(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 c = ka.credit(actor);
        if (c == 0) return;

        vm.prank(actor);
        try ka.withdraw() {
            ghostTotalCredits -= c;
        } catch {}
    }

    function warpForward(uint256 seconds_) external {
        seconds_ = bound(seconds_, 0, EPOCH_SECS * 3);
        skip(seconds_);
    }

    // ── internal helpers ──────────────────────────────────────────────────────

    function _getSubData(uint256 subId) internal view returns (
        address subscriber, uint256 pid, uint64 startEpoch, uint32 epochs, uint32 settled, bool cancelled
    ) {
        (pid, subscriber, startEpoch, epochs, settled, cancelled) = ka.subscriptions(subId);
    }

    function _getSubDataFull(uint256 subId) internal view returns (
        uint256 pid, address subscriber, uint64 startEpoch, uint32 epochs, uint32 settled, bool cancelled
    ) {
        (pid, subscriber, startEpoch, epochs, settled, cancelled) = ka.subscriptions(subId);
    }

    function _getPlanData(uint256 pid) internal view returns (
        address prov, uint96 price, uint32 epochSecs, uint64 startTime, address hbSigner, string memory name
    ) {
        (prov, price, epochSecs, startTime, hbSigner, name) = ka.plans(pid);
    }

    function _getSubscriberCredit(uint256 subId) internal view returns (uint256) {
        (, address subscriber, , , , ) = ka.subscriptions(subId);
        return ka.credit(subscriber);
    }
}

contract KeepaliveInvariantTest is KeepaliveBase {
    KeepaliveHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new KeepaliveHandler(ka, planId, signer);
        targetContract(address(handler));
    }

    /// TC-11: contract balance == sum(credits) + sum(locked subscription funds)
    function invariant_BalanceEqualsLockedPlusCredits() public view {
        assertEq(
            address(ka).balance,
            handler.ghostLockedFunds() + handler.ghostTotalCredits(),
            "balance must equal locked funds + total credits"
        );
    }

    /// Additional: contract balance must never go below total credit owed
    function invariant_BalanceCoversTotalCredits() public view {
        assertGe(
            address(ka).balance,
            handler.ghostTotalCredits(),
            "contract balance must cover all outstanding credits"
        );
    }
}
