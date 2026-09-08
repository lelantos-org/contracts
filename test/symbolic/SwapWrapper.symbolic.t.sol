// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { MockEscrowPool, MockEscrowToken } from "./mocks/MockEscrowPool.sol";

/// Symbolic proofs for the guard block that admits a shielded swap.
///
/// `swap` is permissionless and most of `SwapArgs` is unauthenticated calldata,
/// so `_validate` is the entire boundary between the mempool and a withdraw
/// proof's funds. It runs first and is `view`, and every one of its nine checks
/// reverts before `POOL.withdraw` — which is what makes this file tractable
/// where the swap execution path is not. Nothing below reaches the pool, the
/// adapter or a token; the pool stand-in exists only because the constructor
/// takes one.
///
/// Two of the nine carry most of the weight:
///
/// - **`msg.sender` must be the withdraw proof's `payer`.** `payer` is a public
///   input of that proof and constrains nothing else on the spend path, so it
///   is what names the address allowed to drive the swap. Without it, a
///   withdraw proof observed in the mempool could be replayed under a different
///   `deposit_d` and the output redirected to the replayer. The proof below
///   quantifies over both the caller and the payer, which is the statement
///   "no address but that one", not "some addresses are refused".
/// - **The three identity checks bind the funds to this wrapper.** `recipient`,
///   `relayer` and the deposit's `payer` must all be the wrapper: it is the
///   party that must receive leg 1's output, and the party whose Permit2
///   allowance leg 2 pulls against.
///
/// Worth a solver rather than a fuzzer for the reason the access-control proofs
/// elsewhere in this suite are: each is a statement over the whole address
/// space or the whole timestamp range, and a sampler that draws neither the
/// boundary nor the one permitted value proves nothing about either.
///
/// What is deliberately not here: slippage (`InsufficientOut`), the withdraw
/// receipt floor (`InsufficientWithdraw`) and the closing leftover invariant
/// (`LeftoverBalance`). All three sit past `POOL.withdraw` and
/// `_executeAdapterSwap`, so proving them means executing a spend — the
/// accepting path `README.md` records as out of reach, since it runs
/// `PubInputs.compress`. They stay with `test/swap/`.
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

    uint256 internal constant T0 = 1_000_000;
    uint256 internal constant DEADLINE = T0 + 1 hours;

    function setUp() public {
        vm.warp(T0);
        token = new MockEscrowToken();
        pool = new MockEscrowPool(token);
        wrapper = new SwapWrapper(IMASPPool(address(pool)), IAllowanceTransfer(address(0xBEEF)), OWNER, TREASURY);

        vm.prank(OWNER);
        wrapper.setAdapterAllowed(ADAPTER, true);
    }

    /// A `SwapArgs` that clears every check in `_validate`.
    ///
    /// The proofs below each break exactly one field of it, so a rejection is
    /// attributable to that field rather than to the fixture having drifted out
    /// of validity. `check_validate_acceptsTheWellFormedRequest` is the anchor
    /// that keeps that true: `README.md` records that a revert-only assertion
    /// passes vacuously against a fixture that reverts for an unrelated reason,
    /// and every proof here is a rejection.
    function _args() internal view returns (SwapWrapper.SwapArgs memory a) {
        a.tokenIn = TOKEN_IN;
        a.tokenOut = TOKEN_OUT;
        a.amountIn = 1e18;
        a.minOut = 1e18;
        a.adapter = ADAPTER;
        a.deadline = DEADLINE;
        a.pi_w.recipient = address(wrapper);
        a.pi_w.relayer = address(wrapper);
        a.pi_w.payer = PAYER;
        a.deposit_d.payer = address(wrapper);
    }

    function _swap(SwapWrapper.SwapArgs memory a, address caller) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        return address(wrapper).call(abi.encodeCall(SwapWrapper.swap, (a)));
    }

    /// Non-vacuity anchor. The fixture must get *past* `_validate` — it then
    /// fails in leg 1, where the pool stand-in has no `withdraw`, and that is
    /// the point: reaching a failure that is not one of `_validate`'s nine
    /// selectors is what shows the guard block admitted it.
    function check_validate_acceptsTheWellFormedRequest() public {
        (bool ok, bytes memory ret) = _swap(_args(), PAYER);

        assertFalse(ok, "the stand-in pool has no withdraw; leg 1 must fail");
        _assertNotAValidationRevert(bytes4(ret));
    }

    // --- The front-running guard --------------------------------------------

    /// No address but the withdraw proof's `payer` may drive the swap, for
    /// every caller and every payer.
    ///
    /// This is the guard that makes a withdraw proof safe to broadcast. The
    /// error carries both addresses, so the proof pins them too — a guard that
    /// fired but reported the wrong pair would still let an operator
    /// misdiagnose a replay.
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

    /// Leg 1's output must land on the wrapper. Any other recipient sends the
    /// unshielded funds somewhere the wrapper cannot swap them from, and the
    /// swap would proceed against a balance it does not hold.
    function check_validate_rejectsEveryRecipientButTheWrapper(address recipient) public {
        vm.assume(recipient != address(wrapper));

        SwapWrapper.SwapArgs memory a = _args();
        a.pi_w.recipient = recipient;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(
            ok, ret, SwapWrapper.WrapperNotRecipient.selector, "leg 1 output was directed away from the wrapper"
        );
    }

    /// The relayer note must also be the wrapper's. Defense in depth — MASP
    /// enforces it too — but it reverts here first and for a named reason.
    function check_validate_rejectsEveryRelayerButTheWrapper(address relayer) public {
        vm.assume(relayer != address(wrapper));

        SwapWrapper.SwapArgs memory a = _args();
        a.pi_w.relayer = relayer;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(
            ok, ret, SwapWrapper.WrapperNotRelayer.selector, "the relayer note was directed away from the wrapper"
        );
    }

    /// Leg 2 must escrow as the wrapper. The pull runs against the wrapper's
    /// own Permit2 allowance, so naming any other payer would either fail or —
    /// worse — pull against a third party that had approved the pool.
    function check_validate_rejectsEveryDepositPayerButTheWrapper(address payer) public {
        vm.assume(payer != address(wrapper));

        SwapWrapper.SwapArgs memory a = _args();
        a.deposit_d.payer = payer;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(ok, ret, SwapWrapper.WrapperNotPayer.selector, "leg 2 escrowed as somebody else");
    }

    // --- The venue and expiry guards ----------------------------------------

    /// Only an owner-allowlisted adapter may be used, for every address.
    ///
    /// The adapter is handed the unshielded funds, so this is the allowlist
    /// whose revocation the guardian holds — see
    /// `ProtocolAdmin.symbolic.t.sol`, which proves that revocation is one-way.
    function check_validate_rejectsEveryNonAllowlistedAdapter(address adapter) public {
        vm.assume(adapter != ADAPTER);

        SwapWrapper.SwapArgs memory a = _args();
        a.adapter = adapter;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(
            ok, ret, SwapWrapper.AdapterNotAllowed.selector, "an unallowlisted adapter received escrowed funds"
        );
    }

    /// The deadline is enforced at every timestamp past it, and at none before.
    ///
    /// Both directions in one proof: a swap that expires early is as broken as
    /// one that never expires, and the boundary is inclusive on the accepting
    /// side (`block.timestamp > deadline` reverts, so equality is still live).
    function check_validate_enforcesTheDeadlineAtEveryTimestamp(uint64 t) public {
        SwapWrapper.SwapArgs memory a = _args();

        vm.warp(t);
        (bool ok, bytes memory ret) = _swap(a, PAYER);

        if (t > DEADLINE) {
            _assertRejected(ok, ret, SwapWrapper.SwapExpired.selector, "an expired swap was admitted");
        } else {
            // Still live: it must fail, but somewhere past the guard block.
            assertFalse(ok, "the stand-in pool has no withdraw; nothing here succeeds");
            _assertNotAValidationRevert(bytes4(ret));
        }
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

    /// A zero floor is refused. `minOut` is the only slippage bound the swap
    /// has, so zero would accept any output the adapter cared to return,
    /// including none.
    function check_validate_rejectsZeroMinOut() public {
        SwapWrapper.SwapArgs memory a = _args();
        a.minOut = 0;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(ok, ret, SwapWrapper.MinOutZero.selector);
    }

    /// Input and output must differ, for every token address. A same-token
    /// swap makes the closing leftover invariant compare one balance against
    /// two snapshots, which no honest swap can satisfy.
    function check_validate_rejectsEverySameTokenPair(address t) public {
        SwapWrapper.SwapArgs memory a = _args();
        a.tokenIn = t;
        a.tokenOut = t;

        (bool ok, bytes memory ret) = _swap(a, PAYER);

        _assertRejected(ok, ret, SwapWrapper.SameToken.selector, "a same-token swap was admitted");
    }

    // --- helpers ------------------------------------------------------------

    /// The nine selectors `_validate` can revert with. Used by the accepting
    /// proofs, which cannot assert success — the stand-in pool has no
    /// `withdraw` — and instead assert that the failure came from past the
    /// guard block.
    function _assertNotAValidationRevert(bytes4 sel) internal pure {
        assertTrue(sel != SwapWrapper.AmountInZero.selector, "rejected: AmountInZero");
        assertTrue(sel != SwapWrapper.MinOutZero.selector, "rejected: MinOutZero");
        assertTrue(sel != SwapWrapper.SameToken.selector, "rejected: SameToken");
        assertTrue(sel != SwapWrapper.AdapterNotAllowed.selector, "rejected: AdapterNotAllowed");
        assertTrue(sel != SwapWrapper.SwapExpired.selector, "rejected: SwapExpired");
        assertTrue(sel != SwapWrapper.WrapperNotRecipient.selector, "rejected: WrapperNotRecipient");
        assertTrue(sel != SwapWrapper.WrapperNotRelayer.selector, "rejected: WrapperNotRelayer");
        assertTrue(sel != SwapWrapper.WrapperNotPayer.selector, "rejected: WrapperNotPayer");
        assertTrue(sel != SwapWrapper.UnauthorizedSwapCaller.selector, "rejected: UnauthorizedSwapCaller");
    }

    /// Revert data less its four-byte selector.
    function _body(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = ret[i + 4];
        }
    }
}
