// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Consumes all gas forwarded to any call, for use as a payout recipient, venue
/// adapter, or other callee.
contract GasBurner {
    receive() external payable {
        _burn();
    }

    fallback() external payable {
        _burn();
    }

    function _burn() private pure {
        while (true) { }
    }
}

/// Forwards every call to `NEXT` with all the gas EIP-150 allows and reverts
/// with its own error if that call fails. Chained in front of a `GasBurner`, it
/// models a venue whose out-of-gas happens several frames below the adapter
/// (adapter, router, pool, token), where each frame keeps back 1/64 of its gas
/// and replaces the failure with a revert of its own, as a router wrapping a
/// pool error does.
contract NestedGasBurner {
    address public immutable NEXT;

    error InnerCallFailed();

    constructor(address next) {
        NEXT = next;
    }

    fallback() external payable {
        (bool ok,) = NEXT.call(msg.data);
        if (!ok) revert InnerCallFailed();
    }
}
