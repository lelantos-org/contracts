// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Bundler } from "../../src/bundler/Bundler.sol";

/// Hostile `Bundler` targets for the reentrancy and late-failure tests.

/// Re-enters `Bundler.execute` whenever it is called or paid, recording why the
/// nested call reverted: as a bundled pool target, or as a native payout
/// recipient. The tests make it an operator, so only the guard can stop it.
contract Reenterer {
    Bundler internal bundler;
    bytes public lastError;

    function setBundler(Bundler b) external {
        bundler = b;
    }

    receive() external payable {
        _reenter();
    }

    fallback() external {
        _reenter();
    }

    function _reenter() private {
        try bundler.execute(new Bundler.Call[](0)) { }
        catch (bytes memory err) {
            lastError = err;
        }
    }
}

/// Stands in for a pool whose calls fail as late as possible: it spends gas
/// until what is left is at most the word after the selector, then reverts
/// with a payload longer than `Bundler.MAX_REASON_BYTES`, or runs out of gas
/// trying to.
contract GreedyPool {
    fallback() external {
        uint256 leave = uint256(bytes32(msg.data[4:36]));
        while (gasleft() > leave) { }
        bytes memory payload = new bytes(2048);
        assembly {
            revert(add(payload, 0x20), mload(payload))
        }
    }
}
