// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Keepalive} from "../Keepalive.sol";

/// @dev A malicious contract that tries to re-enter Keepalive.withdraw() on receive().
contract ReentrantWithdrawer {
    Keepalive public keepalive;
    bool public attacked;
    bool public reentered;

    constructor(Keepalive _keepalive) {
        keepalive = _keepalive;
    }

    /// @dev Fund this contract with credit by calling as subscriber.
    function subscribe(uint256 planId, uint32 epochs) external payable {
        keepalive.subscribe{value: msg.value}(planId, epochs);
    }

    function settle(uint256 subId) external {
        keepalive.settle(subId);
    }

    function attack() external {
        attacked = true;
        keepalive.withdraw();
    }

    receive() external payable {
        if (attacked && !reentered) {
            reentered = true;
            // Attempt re-entry — should revert with Reentrancy()
            keepalive.withdraw();
        }
    }
}
