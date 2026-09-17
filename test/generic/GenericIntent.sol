// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SnarkCompression } from "../../src/SnarkCompression.sol";
import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";

/// Test-side `pi_w.intentHash`, written over a `memory` payload independently of
/// `GenericCallWrapper._intentHash`, which reads calldata.
library GenericIntent {
    function hash(GenericCallWrapper.GenericArgs memory a) internal pure returns (uint256) {
        return uint256(
            keccak256(
            abi.encode(
            a.refundTo,
            a.surplusTo,
            a.deadline,
            a.minGas,
            a.calls,
            a.outputs,
            a.refund_d,
            a.refund_aux_d,
            a.refund_fee_aux_d
        )
        )
        ) % SnarkCompression.R;
    }

    /// Stamps `a` with its own intent hash, as an honest wallet would.
    function bind(GenericCallWrapper.GenericArgs memory a)
        internal
        pure
        returns (GenericCallWrapper.GenericArgs memory)
    {
        a.pi_w.intentHash = hash(a);
        return a;
    }
}
