// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Keepalive {
    struct Plan {
        address provider;
        uint96 pricePerEpoch;
        uint32 epochSeconds;
        uint64 startTime;
        address heartbeatSigner;
        string name;
    }

    struct Subscription {
        uint256 planId;
        address subscriber;
        uint64 startEpoch;
        uint32 epochs;
        uint32 settledCount;
        bool cancelled;
    }

    error NotSubscriber();
    error NotHeartbeatSigner();
    error InvalidEpochLength();
    error InvalidPrice();
    error InvalidSigner();
    error InvalidEpochCount();
    error WrongPayment();
    error AlreadyCancelled();
    error WithdrawFailed();
    error Reentrancy();
    error PlanNotFound();
    error TooManyIds();
    error SubscriptionNotFound();
    error EpochTooLong();
    error TooManyEpochs();

    event PlanCreated(uint256 indexed planId, address indexed provider, uint96 pricePerEpoch, uint32 epochSeconds, string name);
    event Heartbeat(uint256 indexed planId, uint256 indexed epoch, uint256 timestamp);
    event Subscribed(
        uint256 indexed subId,
        uint256 indexed planId,
        address indexed subscriber,
        uint64 startEpoch,
        uint32 epochs
    );
    event Settled(uint256 indexed subId, uint256 paidEpochs, uint256 refundedEpochs);
    event Cancelled(uint256 indexed subId, uint256 refundedFuture);
    event Withdrawn(address indexed account, uint256 amount);

    mapping(uint256 => Plan) public plans;
    mapping(uint256 => Subscription) public subscriptions;
    mapping(uint256 => mapping(uint256 => bool)) public alive;
    mapping(address => uint256) public credit;
    mapping(address => uint256[]) private _subscriptionsOf;

    uint256 public planCount;
    uint256 public subCount;

    bool private _locked;

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    function createPlan(
        uint96 pricePerEpoch,
        uint32 epochSeconds,
        address heartbeatSigner,
        string calldata name
    ) external returns (uint256 planId) {
        if (epochSeconds < 60) revert InvalidEpochLength();
        if (epochSeconds > 86400) revert EpochTooLong();
        if (pricePerEpoch == 0) revert InvalidPrice();
        if (heartbeatSigner == address(0)) revert InvalidSigner();

        planId = ++planCount;
        plans[planId] = Plan({
            provider: msg.sender,
            pricePerEpoch: pricePerEpoch,
            epochSeconds: epochSeconds,
            startTime: uint64(block.timestamp),
            heartbeatSigner: heartbeatSigner,
            name: name
        });

        emit PlanCreated(planId, msg.sender, pricePerEpoch, epochSeconds, name);
    }

    function currentEpoch(uint256 planId) public view returns (uint256) {
        Plan storage plan = _getPlan(planId);
        return _currentEpoch(plan);
    }

    function heartbeat(uint256 planId) external {
        Plan storage plan = _getPlan(planId);
        if (msg.sender != plan.heartbeatSigner) revert NotHeartbeatSigner();

        uint256 epoch = _currentEpoch(plan);
        if (alive[planId][epoch]) return;

        alive[planId][epoch] = true;

        emit Heartbeat(planId, epoch, block.timestamp);
    }

    function subscribe(uint256 planId, uint32 epochs) external payable returns (uint256 subId) {
        Plan storage plan = _getPlan(planId);
        if (epochs == 0) revert InvalidEpochCount();
        if (epochs > 10000) revert TooManyEpochs();

        uint256 requiredPayment = uint256(plan.pricePerEpoch) * uint256(epochs);
        if (msg.value != requiredPayment) revert WrongPayment();

        uint256 startEpochValue = _currentEpoch(plan) + 1;
        if (startEpochValue > type(uint64).max) revert InvalidEpochCount();

        subId = ++subCount;
        subscriptions[subId] = Subscription({
            planId: planId,
            subscriber: msg.sender,
            startEpoch: uint64(startEpochValue),
            epochs: epochs,
            settledCount: 0,
            cancelled: false
        });

        _subscriptionsOf[msg.sender].push(subId);

        emit Subscribed(subId, planId, msg.sender, uint64(startEpochValue), epochs);
    }

    function settle(uint256 subId) external {
        Subscription storage sub = _getSubscription(subId);
        (uint256 paidEpochs, uint256 refundedEpochs, uint256 settledNow) = _settleEnded(sub, 256);
        if (settledNow > 0) {
            emit Settled(subId, paidEpochs, refundedEpochs);
        }
    }

    function cancel(uint256 subId) external {
        Subscription storage sub = _getSubscription(subId);
        if (msg.sender != sub.subscriber) revert NotSubscriber();
        if (sub.cancelled) revert AlreadyCancelled();

        (uint256 paidEpochs, uint256 refundedEpochs, uint256 settledNow) = _settleEnded(sub, 256);
        if (settledNow > 0) {
            emit Settled(subId, paidEpochs, refundedEpochs);
        }

        Plan storage plan = _getPlan(sub.planId);
        uint256 startEpochValue = uint256(sub.startEpoch);
        uint256 totalEpochs = uint256(sub.epochs);
        uint256 refundedAmount;

        if (totalEpochs > 0) {
            uint256 current = _currentEpoch(plan);
            uint256 endEpoch = startEpochValue + totalEpochs - 1;

            if (endEpoch > current) {
                // Epochs strictly after `current` have not started yet — refund them immediately.
                // Epoch `current` is in-progress; keep it in sub.epochs so settle() can reach it later.
                uint256 firstFuture = current + 1;
                if (firstFuture < startEpochValue) {
                    // Subscription hasn't started at all — refund everything.
                    firstFuture = startEpochValue;
                    refundedAmount = totalEpochs * uint256(plan.pricePerEpoch);
                    credit[sub.subscriber] += refundedAmount;
                    sub.epochs = 0;
                } else if (firstFuture <= endEpoch) {
                    uint256 refundableEpochs = endEpoch - firstFuture + 1;
                    refundedAmount = refundableEpochs * uint256(plan.pricePerEpoch);
                    credit[sub.subscriber] += refundedAmount;

                    // Keep up to and including current epoch so settle() can resolve it.
                    uint256 keptEpochs = firstFuture - startEpochValue; // = current - startEpochValue + 1
                    sub.epochs = uint32(keptEpochs);
                }
                // If firstFuture > endEpoch, all epochs including current have already ended —
                // _settleEnded already processed them above; nothing left to do.
            }
        }

        sub.cancelled = true;
        emit Cancelled(subId, refundedAmount);
    }

    function withdraw() external nonReentrant {
        uint256 amount = credit[msg.sender];
        credit[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawFailed();

        emit Withdrawn(msg.sender, amount);
    }

    function settleAndWithdraw(uint256[] calldata subIds) external nonReentrant {
        if (subIds.length > 20) revert TooManyIds();

        for (uint256 i = 0; i < subIds.length; i++) {
            uint256 subId = subIds[i];
            Subscription storage sub = _getSubscription(subId);

            if (sub.settledCount >= sub.epochs) {
                continue;
            }

            (uint256 paidEpochs, uint256 refundedEpochs, uint256 settledNow) = _settleEnded(sub, 256);
            if (settledNow > 0) {
                emit Settled(subId, paidEpochs, refundedEpochs);
            }
        }

        uint256 amount = credit[msg.sender];
        if (amount > 0) {
            credit[msg.sender] = 0;

            (bool ok, ) = msg.sender.call{value: amount}("");
            if (!ok) revert WithdrawFailed();

            emit Withdrawn(msg.sender, amount);
        }
    }

    function isAlive(uint256 planId, uint256 epoch) external view returns (bool) {
        return alive[planId][epoch];
    }

    function pending(uint256 subId) external view returns (uint256 toProvider, uint256 toSubscriber) {
        Subscription storage sub = _getSubscription(subId);
        Plan storage plan = _getPlan(sub.planId);

        return _pending(sub, plan);
    }

    function subscriptionState(
        uint256 subId
    ) external view returns (uint256 escrowed, uint256 pendingToProvider, uint256 pendingToSubscriber) {
        Subscription storage sub = _getSubscription(subId);
        Plan storage plan = _getPlan(sub.planId);

        (pendingToProvider, pendingToSubscriber) = _pending(sub, plan);

        uint256 unsettled = uint256(sub.epochs) - uint256(sub.settledCount);
        uint256 totalLocked = uint256(plan.pricePerEpoch) * unsettled;
        uint256 pendingTotal = pendingToProvider + pendingToSubscriber;
        escrowed = totalLocked - pendingTotal;
    }

    function subscriptionsOf(address subscriber) external view returns (uint256[] memory) {
        return _subscriptionsOf[subscriber];
    }

    function _settleEnded(
        Subscription storage sub,
        uint256 maxEpochs
    ) internal returns (uint256 paidEpochs, uint256 refundedEpochs, uint256 settledNow) {
        uint256 totalEpochs = uint256(sub.epochs);
        uint256 settled = uint256(sub.settledCount);

        if (settled >= totalEpochs) {
            return (0, 0, 0);
        }

        Plan storage plan = _getPlan(sub.planId);
        uint256 current = _currentEpoch(plan);
        if (current == 0) {
            return (0, 0, 0);
        }

        uint256 nextEpoch = uint256(sub.startEpoch) + settled;
        uint256 endEpoch = uint256(sub.startEpoch) + totalEpochs - 1;
        uint256 lastEnded = current - 1;

        if (lastEnded > endEpoch) {
            lastEnded = endEpoch;
        }

        if (nextEpoch > lastEnded) {
            return (0, 0, 0);
        }

        settledNow = lastEnded - nextEpoch + 1;
        if (settledNow > maxEpochs) {
            settledNow = maxEpochs;
        }

        for (uint256 i = 0; i < settledNow; i++) {
            uint256 epoch = nextEpoch + i;
            if (alive[sub.planId][epoch]) {
                paidEpochs += 1;
            } else {
                refundedEpochs += 1;
            }
        }

        uint256 price = uint256(plan.pricePerEpoch);
        if (paidEpochs > 0) {
            credit[plan.provider] += paidEpochs * price;
        }
        if (refundedEpochs > 0) {
            credit[sub.subscriber] += refundedEpochs * price;
        }

        sub.settledCount += uint32(settledNow);
    }

    function _pending(
        Subscription storage sub,
        Plan storage plan
    ) internal view returns (uint256 toProvider, uint256 toSubscriber) {
        uint256 start = uint256(sub.startEpoch) + uint256(sub.settledCount);
        uint256 totalEpochs = uint256(sub.epochs);
        uint256 settled = uint256(sub.settledCount);

        if (settled >= totalEpochs) {
            return (0, 0);
        }

        uint256 current = _currentEpoch(plan);
        if (current == 0) {
            return (0, 0);
        }

        uint256 endEpoch = uint256(sub.startEpoch) + totalEpochs - 1;
        uint256 lastEnded = current - 1;
        if (lastEnded > endEpoch) {
            lastEnded = endEpoch;
        }

        if (start > lastEnded) {
            return (0, 0);
        }

        if (lastEnded - start + 1 > 512) {
            lastEnded = start + 511;
        }

        uint256 price = uint256(plan.pricePerEpoch);

        for (uint256 epoch = start; epoch <= lastEnded; epoch++) {
            if (alive[sub.planId][epoch]) {
                toProvider += price;
            } else {
                toSubscriber += price;
            }
        }
    }

    function _currentEpoch(Plan storage plan) internal view returns (uint256) {
        return (block.timestamp - uint256(plan.startTime)) / uint256(plan.epochSeconds);
    }

    function _getPlan(uint256 planId) internal view returns (Plan storage plan) {
        plan = plans[planId];
        if (plan.provider == address(0)) revert PlanNotFound();
    }

    function _getSubscription(uint256 subId) internal view returns (Subscription storage sub) {
        sub = subscriptions[subId];
        if (sub.subscriber == address(0)) revert SubscriptionNotFound();
    }
}
