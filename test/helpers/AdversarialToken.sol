// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "../mocks/Mocks.sol";

/// @dev Transfer behaviour is configured independently of balanceOf/approve.
contract AdversarialToken is MockERC20 {
    enum Reply {
        True,
        Empty,
        False,
        Revert,
        Short,
        InvalidBool
    }

    Reply public reply;
    address public blocked;
    bool public taxIncoming;
    address public callbackTarget;
    bytes public callbackData;
    bool public onPull;
    bool public onSend;
    bool public attempted;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor(uint8 decimals_) MockERC20("Test asset", "TEST", decimals_) {}

    function setReply(Reply reply_) external {
        reply = reply_;
    }

    function setBlocked(address blocked_) external {
        blocked = blocked_;
    }

    function setTaxIncoming(bool enabled) external {
        taxIncoming = enabled;
    }

    function arm(address target, bytes calldata data, bool pull, bool send) external {
        callbackTarget = target;
        callbackData = data;
        onPull = pull;
        onSend = send;
        attempted = false;
        callbackSucceeded = false;
        delete callbackResult;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blocked, "recipient blocked");
        _move(msg.sender, to, amount);
        if (onSend) _callback();
        return _reply();
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(to != blocked, "recipient blocked");
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        _move(from, to, amount);
        if (taxIncoming && amount != 0) {
            balanceOf[to] -= 1;
            totalSupply -= 1;
        }
        if (onPull) _callback();
        return _reply();
    }

    function _callback() private {
        onPull = false;
        onSend = false;
        attempted = true;
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
    }

    function _reply() private view returns (bool) {
        Reply mode = reply;
        if (mode == Reply.Revert) revert("token transfer reverted");
        if (mode == Reply.False) return false;
        if (mode == Reply.Empty) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == Reply.Short) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == Reply.InvalidBool) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return true;
    }
}
