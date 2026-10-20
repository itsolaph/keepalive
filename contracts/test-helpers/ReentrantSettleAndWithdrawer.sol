// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Keepalive} from "../Keepalive.sol";

/// @dev A malicious contract that tries to re-enter Keepalive.settleAndWithdraw() on receive().
contract ReentrantSettleAndWithdrawer {
    Keepalive public keepalive;
    bool public attacked;
    bool public reentered;
    uint256[] internal _subIds;

    constructor(Keepalive _keepalive) {
        keepalive = _keepalive;
    }

    function subscribe(uint256 planId, uint32 epochs) external payable {
        uint256 subId = keepalive.subscribe{value: msg.value}(planId, epochs);
        _subIds.push(subId);
    }

    function settle(uint256 subId) external {
        keepalive.settle(subId);
    }

    function attack(uint256[] calldata subIds) external {
        attacked = true;
        keepalive.settleAndWithdraw(subIds);
    }

    receive() external payable {
        if (attacked && !reentered) {
            reentered = true;
            // Attempt re-entry — should revert with Reentrancy()
            keepalive.settleAndWithdraw(_subIds);
        }
    }
}
