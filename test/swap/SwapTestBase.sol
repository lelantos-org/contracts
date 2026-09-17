// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { SwapIntent } from "./SwapIntent.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { MockSwapAdapter } from "./mocks/MockSwapAdapter.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { WrapperTestBase } from "../utils/WrapperTestBase.sol";

/// Deployment and payload scaffolding shared by the `SwapWrapper` suites.
///
/// `WrapperTestBase` deploys the stub pool, Permit2 and tokens A and B; this
/// adds the wrapper and adapter and the payload builders, so every suite tests
/// the same deployment and a change to the wrapper's constructor or to
/// `SwapArgs` is made in one place.
///
/// `_registerExtraAssets` is the extension point: the binding suite registers a
/// third asset, the only structural difference between the setups.
abstract contract SwapTestBase is WrapperTestBase {
    address internal constant OWNER = address(0xC0FFEE);
    address internal constant TREASURY = TestConstants.TREASURY;
    address internal constant SWAP_REFUND_TO = TestConstants.SWAP_REFUND_TO;

    MockSwapAdapter internal adapter;
    SwapWrapper internal wrapper;

    function setUp() public virtual override {
        super.setUp();
        _registerExtraAssets();
    }

    /// B is armed for the output note, A because a refund escrows `tokenIn`
    /// back; `WrapperTestBase` arms both once this returns.
    function _deployWrapper() internal override {
        adapter = new MockSwapAdapter();
        wrapper = new SwapWrapper(pool, permit2, OWNER, TREASURY);

        vm.prank(OWNER);
        wrapper.setAdapterAllowed(address(adapter), true);
    }

    function _wrapperAddress() internal view override returns (address) {
        return address(wrapper);
    }

    /// Override to register further assets before the suite's first test. Runs
    /// after the wrapper is live, so an override may also call `prepareToken`.
    function _registerExtraAssets() internal virtual { }

    // --- payload builders ---------------------------------------------------

    /// Binds `a` to its own intent, as an honest wallet would, then swaps.
    /// Internal until the wrapper call, so a pending `vm.expectRevert` or
    /// `vm.prank` applies to the swap itself.
    function _swap(SwapWrapper.SwapArgs memory a) internal returns (uint256 actualOut, uint256 depositId) {
        return wrapper.swap(SwapIntent.bind(a));
    }

    /// The well-formed payload every suite starts from: withdraw `piOut` units
    /// of A into the wrapper, swap at least `amountIn` of it through the allowed
    /// adapter for `minOut` of B, and escrow a `depositIn`-unit B note, with the
    /// refund note sized to the withdraw. No deadline; the test contract drives.
    /// Suites overwrite the fields their test is about.
    ///
    /// `tpi_w` and every aux payload stay zero, `ciphertext` empty: the wrapper
    /// does not validate aux, so these suites do not populate it;
    /// `AuxValidation` is covered by the MASP tests.
    function _defaultSwapArgs(uint256 amountIn, uint256 minOut, uint64 piOut, uint64 depositIn)
        internal
        view
        returns (SwapWrapper.SwapArgs memory a)
    {
        a.p_w = FixtureLoader.emptyPoolProof();
        a.tp_w = FixtureLoader.emptyPoolProof();
        a.pi_w = _piWithdraw(piOut, address(wrapper));
        a.deposit_d = _request(depositIn, address(wrapper));
        a.refund_d = _refundRequest(piOut);
        a.adapter = address(adapter);
        a.route = abi.encode(uint24(500), uint160(0));
        a.deadline = type(uint256).max;
        // Distinct from the driver, so a refund that follows `payer` fails the
        // escrow-recovery tests.
        a.refundTo = SWAP_REFUND_TO;
        a.tokenIn = address(tokenA);
        a.tokenOut = address(tokenB);
        a.amountIn = amountIn;
        a.minOut = minOut;
    }

    function _piWithdraw(uint64 publicOut, address recipient) internal view returns (PubInputs.Transact memory pi) {
        pi.publicAssetId = ASSET_A;
        pi.publicOut = publicOut;
        pi.recipient = recipient;
        pi.relayer = recipient;
        // Names the address authorized to drive the swap (see
        // SwapWrapper.UnauthorizedSwapCaller). Tests call as themselves.
        pi.payer = address(this);
    }

    /// The B output note of `publicIn` units, paid by `payer`.
    function _request(uint64 publicIn, address payer) internal view returns (PubInputs.DepositRequest memory) {
        return _noteRequest(ASSET_B, publicIn, payer);
    }
}
