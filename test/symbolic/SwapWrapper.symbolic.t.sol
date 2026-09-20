// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { SwapIntent } from "../swap/SwapIntent.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { MockEscrowPool, MockEscrowToken } from "./mocks/MockEscrowPool.sol";

/// Symbolic proofs for the guard block that admits a shielded swap.
///
/// `swap` is permissionless and most of `SwapArgs` is unauthenticated calldata,
/// so `_validate` is the full boundary between the mempool and a withdraw
/// proof's funds. It runs first, is `view`, and all twelve of its checks revert
/// before `POOL.withdraw`, which keeps these proofs tractable. No proof reaches
/// the adapter or a token; the pool mock is read only for the registry tokens
/// the token binding compares against.
///
/// The two most significant checks:
///
/// - **`msg.sender` must be the withdraw proof's `payer`.** `payer` is a public
///   input of that proof with no other constraint on the spend path, so it names
///   the address allowed to drive the swap. Without this check, anyone could
///   lift a withdraw proof from the mempool and land it. The proof quantifies
///   over both caller and payer, so it states that no other address is accepted.
/// - **The identity checks bind the funds to this wrapper.** `recipient`,
///   `relayer` and both deposits' `payer` must be the wrapper: it receives leg
///   1's output, and its Permit2 allowance funds the output or refund escrow.
/// - **The token checks bind every measured balance to a pool asset.**
///   `tokenIn` must be the withdraw asset's registry token and `tokenOut` the
///   output note's. Otherwise a token with a scripted `balanceOf` satisfies
///   every bound while the refund escrow pulls a real token the wrapper holds.
///
/// Each property ranges over the whole address space or timestamp range, where
/// a fuzzer is unlikely to draw the boundary or the single permitted value.
///
/// Out of scope: deadline and slippage (`SwapExpired`, `InsufficientOut`, both
/// of which refund rather than revert), the withdraw receipt floor
/// (`InsufficientWithdraw`) and the closing leftover invariant
/// (`LeftoverBalance`). All follow `POOL.withdraw`, so proving them requires
/// executing a spend, which runs `PubInputs.compress` (see `README.md`). They
/// are covered in `test/swap/`.
contract SwapWrapperSymbolicTest is GuardAsserts {
    SwapWrapper internal wrapper;
    MockEscrowPool internal pool;
    MockEscrowToken internal token;

    address internal constant OWNER = address(0x0117E7);
    address internal constant TREASURY = address(0xFEE);
    address internal constant ADAPTER = address(0xADA9);
    address internal constant PAYER = address(0xA11CE);

    address internal constant TOKEN_IN = address(0x111);
    address internal constant TOKEN_OUT = address(0x222);
    uint64 internal constant ASSET_IN = 1;
    uint64 internal constant ASSET_OUT = 2;

    uint256 internal constant T0 = 1_000_000;
    uint256 internal constant DEADLINE = T0 + 1 hours;

    function setUp() public {
        vm.warp(T0);
        token = new MockEscrowToken();
        pool = new MockEscrowPool(token);
        pool.setAssetToken(ASSET_IN, TOKEN_IN);
        pool.setAssetToken(ASSET_OUT, TOKEN_OUT);
        wrapper = new SwapWrapper(IMASPPool(address(pool)), IAllowanceTransfer(address(0xBEEF)), OWNER, TREASURY);

        vm.prank(OWNER);
        wrapper.setAdapterAllowed(ADAPTER, true);
    }

    /// A `SwapArgs` that clears every check in `_validate`.
    ///
    /// Each proof below breaks exactly one field, so a rejection is attributable
    /// to that field. `check_validate_acceptsTheWellFormedRequest` shows the
    /// fixture itself passes, so rejection proofs cannot pass vacuously on a
    /// fixture that reverts for an unrelated reason.
    function _args() internal view returns (SwapWrapper.SwapArgs memory a) {
        a.tokenIn = TOKEN_IN;
        a.tokenOut = TOKEN_OUT;
        a.amountIn = 1e18;
        a.minOut = 1e18;
        a.adapter = ADAPTER;
        a.deadline = DEADLINE;
        a.pi_w.publicAssetId = ASSET_IN;
        a.pi_w.recipient = address(wrapper);
        a.pi_w.relayer = address(wrapper);
        a.pi_w.payer = PAYER;
        a.refundTo = PAYER;
        a.deposit_d.publicAssetId = ASSET_OUT;
        a.deposit_d.payer = address(wrapper);
        a.refund_d.publicAssetId = ASSET_IN;
        a.refund_d.payer = address(wrapper);
    }

    function _swap(SwapWrapper.SwapArgs memory a, address caller) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        return address(wrapper).call(abi.encodeCall(SwapWrapper.swap, (SwapIntent.bind(a))));
    }

    /// Non-vacuity: the fixture passes `_validate` and then fails in leg 1,
    /// because the pool mock has no `withdraw`. A failure outside `_validate`'s
    /// twelve selectors shows the guard block admitted the request.
    function check_validate_acceptsTheWellFormedRequest() public {
        (bool ok, bytes memory ret) = _swap(_args(), PAYER);

        assertFalse(ok, "the stand-in pool has no withdraw; leg 1 must fail");
        _assertNotAValidationRevert(bytes4(ret));
    }

    // --- The front-running guard --------------------------------------------

    /// No address but the withdraw proof's `payer` may drive the swap, for
    /// every caller and every payer.
    ///
    /// This makes a withdraw proof safe to broadcast. The error carries both
    /// addresses, and the proof checks them, so a misreported pair cannot
    /// mislead diagnosis of a replay attempt.
    function check_swap_rejectsEveryCallerButTheProofPayer(address caller, address payer) public {
        vm.assume(caller != payer);

        SwapWrapper.SwapArgs memory a = _args();
        a.pi_w.payer = payer;

        (bool ok, bytes memory ret) = _swap(a, caller);

        _assertRejected(
            ok, ret, SwapWrapper.UnauthorizedSwapCaller.selector, "a third party drove someone else's withdraw proof"
        );
        (address reported, address authorized) = abi.decode(_body(ret), (address, address));
        assertEq(reported, caller);
        assertEq(authorized, payer);
    }

    // --- The identity guards ------------------------------------------------

    /// Leg 1's output must go to the wrapper; any other recipient receives the
    /// unshielded funds where the wrapper cannot swap them.
    function check_validate_rejectsEveryRecipientButTheWrapper(address recipient) public {
        vm.assume(recipient != address(wrapper));

        SwapWrapper.SwapArgs memory a = _args();
        a.pi_w.recipient = recipient;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(
            ok, ret, SwapWrapper.WrapperNotRecipient.selector, "leg 1 output was directed away from the wrapper"
        );
    }

    /// The relayer must also be the wrapper. MASP enforces this too; the
    /// wrapper's check is defense in depth and reverts earlier with a named
    /// error.
    function check_validate_rejectsEveryRelayerButTheWrapper(address relayer) public {
        vm.assume(relayer != address(wrapper));

        SwapWrapper.SwapArgs memory a = _args();
        a.pi_w.relayer = relayer;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(
            ok, ret, SwapWrapper.WrapperNotRelayer.selector, "the relayer note was directed away from the wrapper"
        );
    }

    /// Leg 2 must escrow as the wrapper, since the pull runs against the
    /// wrapper's Permit2 allowance. MASP also rejects any other payer
    /// (`PayerNotSender`); this check rejects it before leg 1 with a named error.
    function check_validate_rejectsEveryDepositPayerButTheWrapper(address payer) public {
        vm.assume(payer != address(wrapper));

        SwapWrapper.SwapArgs memory a = _args();
        a.deposit_d.payer = payer;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(ok, ret, SwapWrapper.WrapperNotPayer.selector, "leg 2 escrowed as somebody else");
    }

    /// The refund escrow must also be paid by the wrapper: after a failed venue
    /// leg it is pulled against the wrapper's allowance.
    function check_validate_rejectsEveryRefundPayerButTheWrapper(address payer) public {
        vm.assume(payer != address(wrapper));

        SwapWrapper.SwapArgs memory a = _args();
        a.refund_d.payer = payer;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(ok, ret, SwapWrapper.WrapperNotPayer.selector, "the refund escrowed as somebody else");
    }

    // --- The venue guard -----------------------------------------------------

    /// Only an owner-allowlisted adapter may be used, for every address.
    ///
    /// The adapter receives the unshielded funds. Allowlisting and revoking are
    /// both `onlyOwner`, so each is a governance proposal.
    function check_validate_rejectsEveryNonAllowlistedAdapter(address adapter) public {
        vm.assume(adapter != ADAPTER);

        SwapWrapper.SwapArgs memory a = _args();
        a.adapter = adapter;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(
            ok, ret, SwapWrapper.AdapterNotAllowed.selector, "an unallowlisted adapter received escrowed funds"
        );
    }

    /// The guard block admits the request at every timestamp: an expired swap is
    /// refunded after leg 1 rather than refused.
    function check_validate_admitsTheSwapAtEveryTimestamp(uint64 t) public {
        SwapWrapper.SwapArgs memory a = _args();

        vm.warp(t);
        (bool ok, bytes memory ret) = _swap(a, PAYER);

        // It must fail, but somewhere past the guard block.
        assertFalse(ok, "the stand-in pool has no withdraw; nothing here succeeds");
        _assertNotAValidationRevert(bytes4(ret));
    }

    // --- The degenerate-argument guards -------------------------------------

    /// A zero input is refused. It would unshield nothing and escrow nothing
    /// while still consuming the withdraw proof's nullifiers.
    function check_validate_rejectsZeroAmountIn() public {
        SwapWrapper.SwapArgs memory a = _args();
        a.amountIn = 0;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(ok, ret, SwapWrapper.AmountInZero.selector);
    }

    /// A zero floor is refused. `minOut` is the swap's only slippage bound, so
    /// zero would accept any output from the adapter, including none.
    function check_validate_rejectsZeroMinOut() public {
        SwapWrapper.SwapArgs memory a = _args();
        a.minOut = 0;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(ok, ret, SwapWrapper.MinOutZero.selector);
    }

    /// Input and output must differ, for every token address. For a same-token
    /// swap the closing leftover check would compare one balance against two
    /// snapshots, which a correct swap cannot satisfy.
    function check_validate_rejectsEverySameTokenPair(address t) public {
        SwapWrapper.SwapArgs memory a = _args();
        a.tokenIn = t;
        a.tokenOut = t;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(ok, ret, SwapWrapper.SameToken.selector, "a same-token swap was admitted");
    }

    // --- The token binding ---------------------------------------------------

    /// `tokenIn` must be the registry token of the withdraw proof's asset, for
    /// every address. `tokenIn` is outside the intent hash, so this check is the
    /// only thing tying the balances `swap` measures on the input and refund
    /// legs to the token the pool actually moves.
    function check_validate_rejectsEveryTokenInNotBoundToTheWithdrawAsset(address t) public {
        vm.assume(t != TOKEN_IN && t != TOKEN_OUT);

        SwapWrapper.SwapArgs memory a = _args();
        a.tokenIn = t;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(
            ok, ret, SwapWrapper.TokenInMismatch.selector, "tokenIn is not the token the withdraw proof unshields"
        );
    }

    /// `tokenOut` must be the registry token of the output note's asset, for
    /// every address. `actualOut`, the pull bounds and the leftover check are
    /// all measured in it.
    function check_validate_rejectsEveryTokenOutNotBoundToTheDepositAsset(address t) public {
        vm.assume(t != TOKEN_OUT && t != TOKEN_IN);

        SwapWrapper.SwapArgs memory a = _args();
        a.tokenOut = t;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(
            ok, ret, SwapWrapper.TokenOutMismatch.selector, "tokenOut is not the token the output note escrows"
        );
    }

    // --- helpers ------------------------------------------------------------

    /// Asserts `sel` is none of the twelve selectors `_validate` can revert with.
    /// The accepting proofs cannot assert success (the pool mock has no
    /// `withdraw`), so they assert the failure occurred after the guard block.
    function _assertNotAValidationRevert(bytes4 sel) internal pure {
        assertTrue(sel != SwapWrapper.AmountInZero.selector, "rejected: AmountInZero");
        assertTrue(sel != SwapWrapper.MinOutZero.selector, "rejected: MinOutZero");
        assertTrue(sel != SwapWrapper.SameToken.selector, "rejected: SameToken");
        assertTrue(sel != SwapWrapper.AdapterNotAllowed.selector, "rejected: AdapterNotAllowed");
        assertTrue(sel != SwapWrapper.WrapperNotRecipient.selector, "rejected: WrapperNotRecipient");
        assertTrue(sel != SwapWrapper.WrapperNotRelayer.selector, "rejected: WrapperNotRelayer");
        assertTrue(sel != SwapWrapper.WrapperNotPayer.selector, "rejected: WrapperNotPayer");
        assertTrue(sel != SwapWrapper.UnauthorizedSwapCaller.selector, "rejected: UnauthorizedSwapCaller");
        assertTrue(sel != SwapWrapper.InvalidRefundTo.selector, "rejected: InvalidRefundTo");
        assertTrue(sel != SwapWrapper.TokenInMismatch.selector, "rejected: TokenInMismatch");
        assertTrue(sel != SwapWrapper.TokenOutMismatch.selector, "rejected: TokenOutMismatch");
        assertTrue(sel != SwapWrapper.IntentMismatch.selector, "rejected: IntentMismatch");
    }

    /// Revert data less its four-byte selector.
    function _body(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = ret[i + 4];
        }
    }
}
