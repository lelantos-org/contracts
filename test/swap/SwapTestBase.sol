// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockSwapAdapter } from "./mocks/MockSwapAdapter.sol";
import { MockMASPSwap } from "./mocks/MockMASPSwap.sol";

/// Deployment and payload scaffolding shared by the `SwapWrapper` suites.
///
/// The three suites stood up a byte-identical pool, wrapper, adapter and
/// Permit2 in their own `setUp`, and repeated the same four payload builders.
/// Keeping them in one place means a change to the wrapper's constructor or to
/// `SwapArgs` is edited once instead of three times, and the suites cannot
/// silently drift into testing slightly different deployments.
///
/// `_registerExtraAssets` is the seam: the binding suite needs a third asset,
/// which is the only structural difference between the three setups.
abstract contract SwapTestBase is Test {
    uint64 internal constant ASSET_A = 1;
    uint64 internal constant ASSET_B = 2;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant OWNER = address(0xC0FFEE);
    address internal constant TREASURY = address(0xFEE);

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    IAllowanceTransfer internal permit2;
    MockMASPSwap internal pool;
    MockSwapAdapter internal adapter;
    SwapWrapper internal wrapper;

    function setUp() public virtual {
        permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        pool = new MockMASPSwap(permit2);
        pool.registerAsset(ASSET_A, address(tokenA), SCALE);
        pool.registerAsset(ASSET_B, address(tokenB), SCALE);
        pool.setFeeBps(FEE_BPS);

        adapter = new MockSwapAdapter();
        wrapper = new SwapWrapper(pool, permit2, OWNER, TREASURY);

        vm.prank(OWNER);
        wrapper.setAdapterAllowed(address(adapter), true);

        wrapper.prepareToken(IERC20(address(tokenB)));

        _registerExtraAssets();
    }

    /// Override to register further assets before the suite's first test. Runs
    /// after the wrapper is live, so an override may also call `prepareToken`.
    function _registerExtraAssets() internal virtual { }

    // --- payload builders ---------------------------------------------------

    function _emptyProof() internal pure returns (IMASPPool.Proof memory) {
        return IMASPPool.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    function _emptyTpi() internal pure returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = bytes32(0);
        tpi.newRoot = bytes32(0);
    }

    /// Default-zero `AuxValidation.Output`s; `ciphertext` defaults to empty.
    /// The wrapper never validates aux, so these suites do not populate it —
    /// see `AuxValidation` coverage in the MASP tests instead.
    function _emptyAux() internal pure returns (AuxValidation.Output[6] memory aux) { }

    function _piWithdraw(uint64 publicOut, address recipient) internal view returns (PubInputs.Transact memory pi) {
        pi.publicAssetId = ASSET_A;
        pi.publicOut = publicOut;
        pi.recipient = recipient;
        pi.relayer = recipient;
        // Names the address authorized to drive the swap (see
        // SwapWrapper.UnauthorizedSwapCaller). Tests call as themselves.
        pi.payer = address(this);
    }

    function _request(uint64 publicIn, address payer) internal view returns (PubInputs.DepositRequest memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_B;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = address(0xBEEF);
        d.outCm = bytes32(uint256(1));
        d.feeCm = bytes32(uint256(0xfee));
    }
}
