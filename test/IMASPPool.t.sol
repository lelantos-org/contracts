// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASPTestBase } from "./utils/MASPTestBase.sol";
import { MASP } from "../src/MASP.sol";
import { IMASPPool } from "../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { SpendFixture } from "./utils/SpendFixture.sol";

/// Conformance of `IMASPPool` to `MASP`.
///
/// `IMASPPool` is hand-written, and Solidity never checks it against the
/// contract it claims to describe: a signature that drifts compiles cleanly on
/// both sides and fails only at runtime, as a call to a selector the pool does
/// not implement. That is not a hypothetical — the swap adapter's copy of this
/// interface was left on the pre-fee-note `cancelDeposit`, and
/// `SwapWrapper.cancelEscrow`, the sole recovery path for a swap escrow, could
/// not dispatch at all.
///
/// Two layers here. The selector assertions catch drift at compile time, which
/// is where it belongs. The dispatch tests then call the real pool *through the
/// interface* and require a named MASP error back: a wrong selector on a
/// contract with no fallback reverts with empty returndata, so "reverted with
/// MASP's own error" is proof the call reached the function body.
contract IMASPPoolTest is MASPTestBase {
    // --- compile-time: every selector matches MASP's ------------------------

    function test_selector_withdraw() public pure {
        assertEq(IMASPPool.withdraw.selector, MASP.withdraw.selector, "withdraw drifted");
    }

    function test_selector_depositAuthorized() public pure {
        assertEq(IMASPPool.depositAuthorized.selector, MASP.depositAuthorized.selector, "depositAuthorized drifted");
    }

    function test_selector_cancelDeposit() public pure {
        assertEq(IMASPPool.cancelDeposit.selector, MASP.cancelDeposit.selector, "cancelDeposit drifted");
    }

    /// `escrowed` is a public mapping on MASP, and a getter synthesised from a
    /// state variable has no `.selector` on the contract type. The signature
    /// literal stands in; the dispatch test below is what actually pins it to
    /// the deployed pool.
    function test_selector_escrowed() public pure {
        assertEq(IMASPPool.escrowed.selector, bytes4(keccak256("escrowed(uint256)")), "escrowed drifted");
    }

    // --- runtime: the real pool answers each one ----------------------------

    function _pool() internal view returns (IMASPPool) {
        return IMASPPool(address(masp));
    }

    function test_dispatch_escrowed() public view {
        assertEq(_pool().escrowed(0), bytes32(0), "unknown id reads as the zero sentinel");
    }

    /// The regression for the bug this interface merge fixed. An unknown id is
    /// the cheapest way in: `DepositNotPending` is the first thing
    /// `cancelDeposit` checks, so reaching it proves dispatch succeeded.
    function test_dispatch_cancelDeposit() public {
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, uint256(999)));
        _pool()
            .cancelDeposit(
                999,
                0,
                bytes32(0),
                [uint256(0), 0],
                0,
                0,
                address(0),
                0,
                PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(0), feeCvDep: [uint256(0), 0] })
            );
    }

    function test_dispatch_depositAuthorized() public {
        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid + 1; // first check in `_validateDeposit`
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();

        vm.expectRevert(MASP.BadChainId.selector);
        _pool().depositAuthorized(d, aux[0], aux[1]);
    }

    function test_dispatch_withdraw() public {
        PubInputs.Transact memory pi;
        pi.publicIn = 1; // first check in `withdraw`
        IMASPPool.Proof memory proof;
        PubInputs.TreeUpdateBatch memory tpi;

        vm.expectRevert(MASP.MustNotHaveDeposit.selector);
        _pool().withdraw(proof, pi, proof, tpi, SpendFixture.validAux());
    }
}
