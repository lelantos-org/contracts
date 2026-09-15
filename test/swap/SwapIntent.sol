// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SnarkCompression } from "../../src/SnarkCompression.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";

/// Test-side `pi_w.intentHash`, written over a `memory` payload independently of
/// `SwapWrapper._intentHash`, which reads calldata. Internal, so binding a payload
/// makes no external call and leaves a pending `vm.expectRevert` untouched.
library SwapIntent {
    function hash(SwapWrapper.SwapArgs memory a) internal pure returns (uint256) {
        return uint256(
            keccak256(
            abi.encode(
            a.refundTo,
            a.tokenOut,
            a.minOut,
            a.adapter,
            a.deadline,
            a.deposit_d,
            a.aux_d,
            a.fee_aux_d,
            a.refund_d,
            a.refund_aux_d,
            a.refund_fee_aux_d
        )
        )
        ) % SnarkCompression.R;
    }

    /// Stamps `a` with its own intent hash, as an honest wallet would.
    function bind(SwapWrapper.SwapArgs memory a) internal pure returns (SwapWrapper.SwapArgs memory) {
        a.pi_w.intentHash = hash(a);
        return a;
    }
}
