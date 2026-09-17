// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { GuardAsserts } from "./GuardAsserts.sol";
import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { CallExecutor } from "../../src/generic/CallExecutor.sol";
import { GenericIntent } from "../generic/GenericIntent.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { MockEscrowPool, MockEscrowToken } from "./mocks/MockEscrowPool.sol";

/// Symbolic proofs for the guard block that admits a generic call execution.
///
/// As in `SwapWrapper.symbolic.t.sol`, every guard in `_validate` reverts before
/// `POOL.withdraw`, so each property is a rejection over the whole address or
/// id space, plus one non-vacuity anchor. The call leg and the escrow bounds sit
/// past a completed spend and stay with `test/generic/`; the pull bounds they
/// rely on are proved for `MaspEscrowSatellite._escrowMeasured`.
contract GenericCallWrapperSymbolicTest is GuardAsserts {
    GenericCallWrapper internal wrapper;
    MockEscrowPool internal pool;

    address internal constant PAYER = address(0xA11CE);
    address internal constant TOKEN_IN = address(0x111);
    address internal constant TOKEN_OUT = address(0x222);
    uint64 internal constant ASSET_IN = 1;
    uint64 internal constant ASSET_OUT = 2;

    function setUp() public {
        pool = new MockEscrowPool(new MockEscrowToken());
        pool.setAssetToken(ASSET_IN, TOKEN_IN);
        pool.setAssetToken(ASSET_OUT, TOKEN_OUT);
        wrapper = new GenericCallWrapper(IMASPPool(address(pool)), IAllowanceTransfer(address(0xBEEF)));
    }

    /// A payload that clears every check in `_validate`; each proof breaks one field.
    function _args() internal view returns (GenericCallWrapper.GenericArgs memory a) {
        a.amountIn = 1;
        a.deadline = type(uint256).max;
        a.refundTo = PAYER;
        a.surplusTo = PAYER;
        a.pi_w.publicAssetId = ASSET_IN;
        a.pi_w.recipient = address(wrapper);
        a.pi_w.relayer = address(wrapper);
        a.pi_w.payer = PAYER;
        a.refund_d.publicAssetId = ASSET_IN;
        a.refund_d.payer = address(wrapper);
        a.calls = new CallExecutor.Call[](0);
        a.outputs = new GenericCallWrapper.Output[](1);
        a.outputs[0].minOut = 1;
        a.outputs[0].deposit.publicAssetId = ASSET_OUT;
        a.outputs[0].deposit.payer = address(wrapper);
    }

    function _execute(GenericCallWrapper.GenericArgs memory a, address caller)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(caller);
        return address(wrapper).call(abi.encodeCall(GenericCallWrapper.execute, (GenericIntent.bind(a))));
    }

    /// Non-vacuity: the fixture clears `_validate` and fails in leg 1, because
    /// the stand-in pool has no `withdraw`.
    function check_validate_acceptsTheWellFormedRequest() public {
        (bool ok, bytes memory ret) = _execute(_args(), PAYER);
        assertFalse(ok, "the stand-in pool has no withdraw; leg 1 must fail");
        _assertNotAValidationRevert(bytes4(ret));
    }

    /// No address but the withdraw proof's `payer` may drive an execution.
    function check_execute_rejectsEveryCallerButTheProofPayer(address caller, address payer) public {
        vm.assume(caller != payer);
        GenericCallWrapper.GenericArgs memory a = _args();
        a.pi_w.payer = payer;
        (bool ok, bytes memory ret) = _execute(a, caller);
        _assertRejected(ok, ret, GenericCallWrapper.UnauthorizedCaller.selector, "a third party drove the proof");
    }

    function check_validate_rejectsEveryRecipientButTheWrapper(address recipient) public {
        vm.assume(recipient != address(wrapper));
        GenericCallWrapper.GenericArgs memory a = _args();
        a.pi_w.recipient = recipient;
        (bool ok, bytes memory ret) = _execute(a, PAYER);
        _assertRejected(ok, ret, GenericCallWrapper.WrapperNotRecipient.selector);
    }

    function check_validate_rejectsEveryRelayerButTheWrapper(address relayer) public {
        vm.assume(relayer != address(wrapper));
        GenericCallWrapper.GenericArgs memory a = _args();
        a.pi_w.relayer = relayer;
        (bool ok, bytes memory ret) = _execute(a, PAYER);
        _assertRejected(ok, ret, GenericCallWrapper.WrapperNotRelayer.selector);
    }

    /// Every escrow is pulled against the wrapper's own Permit2 allowance.
    function check_validate_rejectsEveryOutputPayerButTheWrapper(address payer) public {
        vm.assume(payer != address(wrapper));
        GenericCallWrapper.GenericArgs memory a = _args();
        a.outputs[0].deposit.payer = payer;
        (bool ok, bytes memory ret) = _execute(a, PAYER);
        _assertRejected(ok, ret, GenericCallWrapper.WrapperNotPayer.selector);
    }

    function check_validate_rejectsEveryRefundPayerButTheWrapper(address payer) public {
        vm.assume(payer != address(wrapper));
        GenericCallWrapper.GenericArgs memory a = _args();
        a.refund_d.payer = payer;
        (bool ok, bytes memory ret) = _execute(a, PAYER);
        _assertRejected(ok, ret, GenericCallWrapper.WrapperNotPayer.selector);
    }

    /// The refund must be escrowed in the token leg 1 delivers, for every asset id.
    function check_validate_rejectsEveryRefundAssetInAnotherToken(uint64 id, address token) public {
        vm.assume(token != TOKEN_IN && id != ASSET_IN);
        pool.setAssetToken(id, token);
        GenericCallWrapper.GenericArgs memory a = _args();
        a.refund_d.publicAssetId = id;
        (bool ok, bytes memory ret) = _execute(a, PAYER);
        _assertRejected(ok, ret, GenericCallWrapper.TokenInMismatch.selector);
    }

    /// No yield asset is escrowed, as an output, for any id.
    function check_validate_rejectsEveryYieldOutput(uint64 id) public {
        pool.setYieldAsset(id, true);
        GenericCallWrapper.GenericArgs memory a = _args();
        a.outputs[0].deposit.publicAssetId = id;
        (bool ok, bytes memory ret) = _execute(a, PAYER);
        _assertRejected(ok, ret, GenericCallWrapper.YieldAssetNotSupported.selector);
    }

    /// Two outputs never share a token, whichever asset ids name it.
    function check_validate_rejectsEverySharedOutputToken(uint64 id, uint64 other) public {
        vm.assume(id != ASSET_IN && other != ASSET_IN);
        pool.setAssetToken(id, TOKEN_OUT);
        pool.setAssetToken(other, TOKEN_OUT);
        GenericCallWrapper.GenericArgs memory a = _args();
        GenericCallWrapper.Output[] memory outs = new GenericCallWrapper.Output[](2);
        outs[0] = a.outputs[0];
        outs[0].deposit.publicAssetId = id;
        outs[1] = a.outputs[0];
        outs[1].deposit.publicAssetId = other;
        a.outputs = outs;
        (bool ok, bytes memory ret) = _execute(a, PAYER);
        _assertRejected(ok, ret, GenericCallWrapper.DuplicateOutputToken.selector);
    }

    function check_validate_rejectsSelfAsReceiver() public {
        GenericCallWrapper.GenericArgs memory a = _args();
        a.refundTo = address(wrapper);
        (bool ok, bytes memory ret) = _execute(a, PAYER);
        _assertRejected(ok, ret, GenericCallWrapper.InvalidRefundTo.selector);

        a = _args();
        a.surplusTo = address(wrapper);
        (ok, ret) = _execute(a, PAYER);
        _assertRejected(ok, ret, GenericCallWrapper.InvalidSurplusTo.selector);
    }

    /// Asserts `sel` is none of the selectors `_validate` can revert with.
    function _assertNotAValidationRevert(bytes4 sel) internal pure {
        assertTrue(sel != GenericCallWrapper.AmountInZero.selector, "rejected: AmountInZero");
        assertTrue(sel != GenericCallWrapper.MinOutZero.selector, "rejected: MinOutZero");
        assertTrue(sel != GenericCallWrapper.BadOutputCount.selector, "rejected: BadOutputCount");
        assertTrue(sel != GenericCallWrapper.TooManyCalls.selector, "rejected: TooManyCalls");
        assertTrue(sel != GenericCallWrapper.DuplicateOutputToken.selector, "rejected: DuplicateOutputToken");
        assertTrue(sel != GenericCallWrapper.YieldAssetNotSupported.selector, "rejected: YieldAssetNotSupported");
        assertTrue(sel != GenericCallWrapper.WrapperNotRecipient.selector, "rejected: WrapperNotRecipient");
        assertTrue(sel != GenericCallWrapper.WrapperNotRelayer.selector, "rejected: WrapperNotRelayer");
        assertTrue(sel != GenericCallWrapper.WrapperNotPayer.selector, "rejected: WrapperNotPayer");
        assertTrue(sel != GenericCallWrapper.UnauthorizedCaller.selector, "rejected: UnauthorizedCaller");
        assertTrue(sel != GenericCallWrapper.InvalidRefundTo.selector, "rejected: InvalidRefundTo");
        assertTrue(sel != GenericCallWrapper.InvalidSurplusTo.selector, "rejected: InvalidSurplusTo");
        assertTrue(sel != GenericCallWrapper.TokenInMismatch.selector, "rejected: TokenInMismatch");
        assertTrue(sel != GenericCallWrapper.IntentMismatch.selector, "rejected: IntentMismatch");
    }
}
