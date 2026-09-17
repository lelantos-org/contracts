// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { PubInputs } from "../../src/libs/PubInputs.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockMASPSwap } from "../swap/mocks/MockMASPSwap.sol";
import { TestConstants } from "./TestConstants.sol";
import { DepositFixture } from "./DepositFixture.sol";
import { FeeMath } from "./FeeMath.sol";

/// The one wrapper entry point this base drives. `prepareToken` is declared by
/// each wrapper rather than by `MaspEscrowSatellite`, so the base reaches it
/// through this interface instead of naming either wrapper type.
interface IWrapperTokenPrep {
    function prepareToken(IERC20 token) external;
}

/// Deployment and amount scaffolding shared by the escrow-wrapper suites
/// (`SwapTestBase`, `GenericCallTestBase`).
///
/// Both wrap the same stub pool: Permit2, `MockMASPSwap` at one scale and fee,
/// and tokens A and B, each registered on the pool and armed on the wrapper.
/// Keeping that here means a change to the stub pool's wiring or to its fee
/// model is made once rather than drifting between the two suites.
///
/// `setUp` is a template. The per-domain base supplies the wrapper
/// (`_deployWrapper`, `_wrapperAddress`) and may add tokens (`_deployExtraTokens`,
/// `_assets`). Contracts are created in the order the suites used before this
/// base existed, so every deployed address is unchanged.
abstract contract WrapperTestBase is Test {
    uint64 internal constant ASSET_A = 1;
    uint64 internal constant ASSET_B = 2;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    /// Owner of every output note the suites build.
    address internal constant NOTE_RECIPIENT = address(0xBEEF);

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    IAllowanceTransfer internal permit2;
    MockMASPSwap internal pool;

    function setUp() public virtual {
        permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        _deployExtraTokens();

        (uint64[] memory ids, address[] memory tokens) = _assets();
        pool = new MockMASPSwap(permit2);
        for (uint256 i; i < ids.length; ++i) {
            pool.registerAsset(ids[i], tokens[i], SCALE);
        }
        pool.setFeeBps(FEE_BPS);

        _deployWrapper();

        // Every registered asset can be escrowed: an output note, or a refund
        // of the input back into the pool.
        for (uint256 i; i < tokens.length; ++i) {
            IWrapperTokenPrep(_wrapperAddress()).prepareToken(IERC20(tokens[i]));
        }
    }

    // --- hooks ---------------------------------------------------------------

    /// Override to deploy tokens beyond A and B. Runs before the pool exists, so
    /// the pool's address does not depend on how many tokens a suite adds later.
    function _deployExtraTokens() internal virtual { }

    /// The assets registered on the pool and armed on the wrapper. Override,
    /// including A and B, to list more.
    function _assets() internal view virtual returns (uint64[] memory ids, address[] memory tokens) {
        ids = new uint64[](2);
        tokens = new address[](2);
        (ids[0], tokens[0]) = (ASSET_A, address(tokenA));
        (ids[1], tokens[1]) = (ASSET_B, address(tokenB));
    }

    /// Deploys and configures the suite's wrapper against `pool` and `permit2`.
    function _deployWrapper() internal virtual;

    /// The wrapper under test: the payer of every note it escrows.
    function _wrapperAddress() internal view virtual returns (address);

    // --- amounts ---------------------------------------------------------------

    /// `amount` net of the stub pool's fee: what a withdraw of `amount` delivers.
    function _netOfFee(uint256 amount) internal pure returns (uint256) {
        return amount - FeeMath.fee(amount, FEE_BPS);
    }

    /// The largest note of the withdrawn asset whose pull, fee included, fits
    /// what a withdraw of `units` nets. Two fees come off: the unshield on the
    /// way out and the deposit on the way back in.
    function _netOfTwoFees(uint64 units) internal pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64((uint256(units) * (FeeMath.BPS - 2 * uint256(FEE_BPS))) / FeeMath.BPS);
    }

    // --- payloads --------------------------------------------------------------

    /// A note of `publicIn` units of `assetId` for `NOTE_RECIPIENT`, paid by
    /// `payer`, with commitment 1.
    function _noteRequest(uint64 assetId, uint64 publicIn, address payer)
        internal
        view
        returns (PubInputs.DepositRequest memory)
    {
        return DepositFixture.request(assetId, publicIn, payer, NOTE_RECIPIENT, bytes32(uint256(1)));
    }

    /// The A note a payload withdrawing `withdrawUnits` of A refunds to when its
    /// calls fail. Commitment 2, so it is distinguishable from the output note.
    function _refundRequest(uint64 withdrawUnits) internal view returns (PubInputs.DepositRequest memory d) {
        d = _noteRequest(ASSET_A, _netOfTwoFees(withdrawUnits), _wrapperAddress());
        d.outCm = bytes32(uint256(2));
    }
}
