// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { ERC4626Venue } from "../../src/yield/ERC4626Venue.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { uniformBps } from "../utils/FeeArrays.sol";

/// Shared rig for the yield-index tests.
///
/// One ERC-20 registered twice: `PLAIN_ID` with no venue and `YIELD_ID` bound
/// to a `MockERC4626`. That is the production shape — a token's plain and yield
/// ids differ in nothing but the binding — and it is what makes the isolation
/// assertions meaningful, since both ids draw on the same `balanceOf`.
///
/// Both Groth16 verifiers are mocked to accept, isolating the index arithmetic
/// from circuit correctness the way `MASP.doubleSpend.t.sol` does.
contract YieldBase is Test {
    uint64 internal constant PLAIN_ID = 1;
    uint64 internal constant YIELD_ID = 9;
    /// A second yield asset differing from `YIELD_ID` in `scale` alone. The
    /// index divides by `supply * scale`, so a formula that drops `scale`
    /// passes every `scale = 1` test and is wrong by ten orders of magnitude
    /// for an 18-decimal asset. Having both registered lets a test compare them
    /// directly.
    uint64 internal constant FINE_ID = 11;
    uint256 internal constant FINE_SCALE = 1;
    /// 1e10, matching the deployed WETH rows. USDC's `scale = 1` would let an
    /// index formula that drops `scale` pass; this one will not.
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    uint16 internal constant BUFFER_BPS = 500; // 5% kept unlent
    uint16 internal constant PERF_BPS = 1000; // 10% of yield
    uint256 internal constant RAY = 1e27;

    address internal constant RELAYER = address(0xCA11);
    address internal constant SPEND_PAYER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xF00D);
    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);

    MockERC20 internal token;
    MockERC4626 internal vault;
    ERC4626Venue internal venue;
    MockERC4626 internal vaultFine;
    ERC4626Venue internal venueFine;
    MockBatchVerifier internal batchVerifier;
    IVerifier internal tubVerifier;
    MASP internal masp;
    address internal permit2;

    address internal payer = address(0xa11ce);

    function setUp() public virtual {
        token = new MockERC20("M", "M", 18);
        tubVerifier = IVerifier(address(new MockERC20("tub", "tub", 18)));
        batchVerifier = new MockBatchVerifier();
        permit2 = new DeployPermit2().deployPermit2();

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = PLAIN_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;

        masp = new MASP(
            tubVerifier,
            batchVerifier,
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            uniformBps(ids.length, FEE_BPS),
            uniformBps(ids.length, FEE_BPS),
            TREASURY,
            OWNER
        );

        // The venue is pinned to the pool, so it cannot exist before the pool
        // does — which is why a yield asset is registered post-deploy.
        vault = new MockERC4626(IERC20(address(token)));
        venue = new ERC4626Venue(address(masp), address(vault), address(token));
        vm.prank(OWNER);
        masp.addYieldAsset(
            YIELD_ID, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(venue), BUFFER_BPS, PERF_BPS
        );

        vaultFine = new MockERC4626(IERC20(address(token)));
        venueFine = new ERC4626Venue(address(masp), address(vaultFine), address(token));
        vm.prank(OWNER);
        masp.addYieldAsset(
            FINE_ID, IERC20(address(token)), FINE_SCALE, FEE_BPS, FEE_BPS, address(venueFine), BUFFER_BPS, PERF_BPS
        );

        batchVerifier.setResult(true);
        vm.mockCall(address(tubVerifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));

        vm.prank(payer);
        token.approve(permit2, type(uint256).max);
    }

    // --- helpers ------------------------------------------------------------

    function _allow(uint160 cap) internal {
        vm.prank(payer);
        IAllowanceTransfer(permit2).approve(address(token), address(masp), cap, uint48(block.timestamp + 365 days));
    }

    /// Commitments are small consecutive integers, not hashes: they are fed to
    /// `PubInputs.compress`, which rejects anything at or above the SNARK field
    /// modulus.
    function _request(uint64 id, uint64 publicIn, uint64 feeIn, uint256 seed)
        internal
        view
        returns (PubInputs.DepositRequest memory d)
    {
        d.chainId = block.chainid;
        d.publicAssetId = id;
        d.publicIn = publicIn;
        d.feeIn = feeIn;
        d.payer = payer;
        d.recipient = RECIPIENT;
        d.outCm = bytes32(seed);
        d.feeCm = bytes32(seed + 1);
    }

    /// Deposit into `id` and return the escrow id. Mints and approves whatever
    /// the pool asks for, so the index may move freely between calls.
    function _deposit(uint64 id, uint64 publicIn, uint256 seed) internal returns (uint256 depositId, uint256 pulled) {
        token.mint(payer, type(uint128).max);
        _allow(type(uint160).max);
        PubInputs.DepositRequest memory d = _request(id, publicIn, 0, seed);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        uint256 before = token.balanceOf(payer);
        vm.prank(payer);
        depositId = masp.depositAuthorized(d, aux[0], aux[1]);
        pulled = before - token.balanceOf(payer);
    }

    /// Unshield `publicOut` units of `id` to `RECIPIENT`.
    function _withdraw(uint64 id, uint64 publicOut, uint256 nfSeed) internal {
        PubInputs.Transact memory pi;
        pi.chainId = block.chainid;
        pi.publicAssetId = id;
        pi.publicOut = publicOut;
        pi.recipient = RECIPIENT;
        pi.payer = SPEND_PAYER;
        pi.relayer = RELAYER;
        SpendFixture.fillOutputs(pi, nfSeed, nfSeed + 0x1000);
        pi.merkleRoot = masp.currentRoot();
        PubInputs.TreeUpdateBatch memory tpi =
            SpendFixture.batchFor(pi, masp.currentRoot(), bytes32(nfSeed + 0x2_0000), masp.committedCount());
        vm.prank(RELAYER);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// Credit `amt` of interest inside `v`.
    function _earnInto(MockERC4626 v, uint256 amt) internal {
        if (amt == 0) return;
        token.mint(address(this), amt);
        token.approve(address(v), amt);
        v.earn(amt);
    }

    /// Credit `amt` of interest inside the main vault.
    function _earn(uint256 amt) internal {
        _earnInto(vault, amt);
    }

    function _supply(uint64 id) internal view returns (uint256) {
        YieldIndex.YieldState memory st = masp.yieldState(id);
        return st.totalNormalized + st.accruedFeeNormalized;
    }

    function _gross(uint64 id) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(venue))) + masp.yieldState(id).idle;
    }

    function _idle(uint64 id) internal view returns (uint256) {
        return masp.yieldState(id).idle;
    }
}
