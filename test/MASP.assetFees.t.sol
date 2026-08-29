// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { AssetRegistry } from "../src/AssetRegistry.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC1271 } from "./mocks/MockERC1271.sol";
import { MockBatchVerifier } from "./mocks/MockBatchVerifier.sol";
import { SpendFixture } from "./utils/SpendFixture.sol";
import { FixtureLoader } from "./utils/FixtureLoader.sol";
import { uniformBps } from "./utils/FeeArrays.sol";

/// Per-asset deposit and withdraw rates. There is no pool-wide rate and no
/// inheritance: every asset stores its own pair, and a stored `0` means 0.
///
/// Both verifiers are mocked to accept any proof — the subject is rate
/// selection and blast radius, not circuit correctness.
///
/// The property that replaces the old fallback semantics: a fee change reaches
/// exactly the ids named in the call. No setter can re-rate an asset the owner
/// did not mention.
contract MASPAssetFeesTest is Test {
    uint64 internal constant ASSET_ID = 1;
    uint64 internal constant OTHER_ID = 2;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant GENESIS_BPS = 25;
    uint16 internal constant MAX_BPS = 2_000;

    address internal constant OWNER = address(0x0117e7);
    address internal constant TREASURY = address(0xfee);
    address internal constant RELAYER = address(0xCA11);
    address internal constant PAYER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xF00D);

    MockERC20 internal token;
    MockERC20 internal other;
    IVerifier internal tubVerifier;
    MockBatchVerifier internal batchVerifier;
    address internal permit2;
    MASP internal masp;

    function setUp() public {
        token = new MockERC20("M", "M", 18);
        other = new MockERC20("N", "N", 18);
        tubVerifier = IVerifier(address(new MockERC20("tub", "tub", 18)));
        batchVerifier = new MockBatchVerifier();
        permit2 = new DeployPermit2().deployPermit2();

        uint64[] memory ids = new uint64[](2);
        IERC20[] memory tokens = new IERC20[](2);
        uint256[] memory scales = new uint256[](2);
        ids[0] = ASSET_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;
        ids[1] = OTHER_ID;
        tokens[1] = IERC20(address(other));
        scales[1] = SCALE;

        masp = new MASP(
            tubVerifier,
            batchVerifier,
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            uniformBps(ids.length, GENESIS_BPS),
            uniformBps(ids.length, GENESIS_BPS),
            TREASURY,
            OWNER
        );

        batchVerifier.setResult(true);
        vm.mockCall(address(tubVerifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));

        // Permissive ERC-1271 stub at the payer so any signature bytes pass
        // Permit2; the subject is the amount pulled, not the signature.
        MockERC1271 stub = new MockERC1271();
        vm.etch(PAYER, address(stub).code);
    }

    // --- helpers -----------------------------------------------------------

    function _setFee(uint64 id, uint16 dep, uint16 wit) internal {
        vm.prank(OWNER);
        masp.setAssetFee(id, dep, wit);
    }

    function _request(uint64 publicIn) internal view returns (PubInputs.DepositRequest memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = PAYER;
        d.recipient = RECIPIENT;
        d.outCm = bytes32(uint256(0xdead));
        d.feeCm = bytes32(uint256(0xfee));
    }

    function _sig(uint256 maxTotal) internal pure returns (MASP.Permit2Sig memory) {
        return MASP.Permit2Sig({ nonce: 0, deadline: type(uint256).max, maxTotal: maxTotal, signature: hex"00" });
    }

    function _fundPayer(uint256 amount) internal {
        token.mint(PAYER, amount);
        vm.prank(PAYER);
        token.approve(permit2, type(uint256).max);
    }

    function _aux() internal pure returns (AuxValidation.Output[6] memory) {
        return SpendFixture.validAux();
    }

    /// `publicOut = 1`, i.e. `SCALE` base units gross.
    function _withdraw() internal {
        bytes32 root = masp.currentRoot();
        PubInputs.Transact memory pi;
        pi.chainId = block.chainid;
        pi.publicAssetId = ASSET_ID;
        pi.publicIn = 0;
        pi.publicOut = 1;
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = RELAYER;
        SpendFixture.fillOutputs(pi, 0x1111, 0x3333);
        pi.merkleRoot = root;
        PubInputs.TreeUpdateBatch memory tpi = SpendFixture.batchFor(pi, root, bytes32(uint256(0xABCD)), 0);

        vm.prank(RELAYER);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, _aux());
    }

    // --- resolution --------------------------------------------------------

    /// The constructor's rate is a starting value written into each genesis
    /// entry, not a fallback consulted later.
    function test_genesisRateIsWrittenToBothLegs() public view {
        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, GENESIS_BPS);
        assertEq(wit, GENESIS_BPS);
    }

    /// The shape the fee policy wants: free to enter, charged on exit.
    function test_setAssetFee_setsLegsIndependently() public {
        _setFee(ASSET_ID, 0, 50);
        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, 0, "deposit free");
        assertEq(wit, 50, "withdraw charged");
    }

    /// What removing the fallback buys: a rate change has a blast radius of
    /// exactly one id.
    function test_feeChange_touchesOnlyTheNamedAsset() public {
        _setFee(ASSET_ID, 0, 900);

        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, 0);
        assertEq(wit, 900);

        (uint16 odep, uint16 owit) = masp.assetFees(OTHER_ID);
        assertEq(odep, GENESIS_BPS, "untouched asset keeps its rate");
        assertEq(owit, GENESIS_BPS);
    }

    /// A registered zero is a real rate and stays one.
    function test_zeroIsALiteralRate() public {
        _setFee(ASSET_ID, 0, 0);
        _setFee(OTHER_ID, 1_000, 1_000);

        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, 0, "still zero after another asset is re-rated");
        assertEq(wit, 0);
    }

    function test_addAsset_requiresRatesAndBoundsThem() public {
        MockERC20 fresh = new MockERC20("F", "F", 18);

        vm.prank(OWNER);
        vm.expectRevert(AssetRegistry.AssetFeeTooHigh.selector);
        masp.addAsset(3, IERC20(address(fresh)), 1, MAX_BPS + 1, 0);

        vm.prank(OWNER);
        masp.addAsset(3, IERC20(address(fresh)), 1, 0, 777);
        (uint16 dep, uint16 wit) = masp.assetFees(3);
        assertEq(dep, 0);
        assertEq(wit, 777);
    }

    function test_setAssetFee_acceptsCeiling() public {
        _setFee(ASSET_ID, MAX_BPS, MAX_BPS);
        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, MAX_BPS);
        assertEq(wit, MAX_BPS);
    }

    function test_setAssetFee_rejectsAboveCeilingOnEitherLeg() public {
        vm.prank(OWNER);
        vm.expectRevert(AssetRegistry.AssetFeeTooHigh.selector);
        masp.setAssetFee(ASSET_ID, MAX_BPS + 1, 0);

        vm.prank(OWNER);
        vm.expectRevert(AssetRegistry.AssetFeeTooHigh.selector);
        masp.setAssetFee(ASSET_ID, 0, MAX_BPS + 1);
    }

    function testFuzz_setAssetFee_ceilingHolds(uint16 dep, uint16 wit) public {
        vm.prank(OWNER);
        if (dep > MAX_BPS || wit > MAX_BPS) {
            vm.expectRevert(AssetRegistry.AssetFeeTooHigh.selector);
            masp.setAssetFee(ASSET_ID, dep, wit);
        } else {
            masp.setAssetFee(ASSET_ID, dep, wit);
            (uint16 gotDep, uint16 gotWit) = masp.assetFees(ASSET_ID);
            assertEq(gotDep, dep);
            assertEq(gotWit, wit);
        }
    }

    function test_setAssetFee_onlyOwner() public {
        address attacker = address(0xa11ce);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        masp.setAssetFee(ASSET_ID, 1, 1);
    }

    function test_unknownAsset_revertsOnEveryEntryPoint() public {
        uint64 ghost = 99;

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, ghost));
        masp.setAssetFee(ghost, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, ghost));
        masp.assetFees(ghost);
    }

    /// Indexers follow `AssetFeeSet` for both registration and changes, so it
    /// must fire on each. `AssetRegistered` keeps its existing shape.
    function test_assetFeeSet_emittedOnChangeAndOnRegistration() public {
        vm.expectEmit(true, false, false, true, address(masp));
        emit AssetRegistry.AssetFeeSet(ASSET_ID, 7, 9);
        vm.prank(OWNER);
        masp.setAssetFee(ASSET_ID, 7, 9);

        MockERC20 fresh = new MockERC20("F", "F", 18);
        vm.expectEmit(true, false, false, true, address(masp));
        emit AssetRegistry.AssetFeeSet(4, 3, 5);
        vm.prank(OWNER);
        masp.addAsset(4, IERC20(address(fresh)), 1, 3, 5);
    }

    // --- deposit leg -------------------------------------------------------

    function test_deposit_chargesTheAssetsOwnRate() public {
        uint16 rate = 500; // 5%, vs the 0.25% it was registered at
        _setFee(ASSET_ID, rate, 0);

        uint64 publicIn = 100;
        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 expected = inAmt + (inAmt * rate) / 10_000;
        _fundPayer(expected);

        uint256 before = token.balanceOf(address(masp));
        masp.deposit(_request(publicIn), _sig(expected), _aux()[0], _aux()[1]);

        assertEq(token.balanceOf(address(masp)) - before, expected, "pulled at the asset rate");
    }

    function test_deposit_zeroRate_chargesPrincipalOnly() public {
        _setFee(ASSET_ID, 0, 0);

        uint64 publicIn = 100;
        uint256 inAmt = uint256(publicIn) * SCALE;
        _fundPayer(inAmt);

        uint256 before = token.balanceOf(address(masp));
        masp.deposit(_request(publicIn), _sig(inAmt), _aux()[0], _aux()[1]);

        assertEq(token.balanceOf(address(masp)) - before, inAmt, "no fee on top");
    }

    /// The deposit leg is protected by the signed ceiling: raising the rate
    /// after the payer signed cannot make them pay more, it makes the pull
    /// exceed `maxTotal` and Permit2 refuses. The withdraw leg has no
    /// equivalent — see `_unshieldLeg`.
    function test_deposit_signedCeilingBoundsALaterRateRaise() public {
        uint64 publicIn = 100;
        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 signedTotal = inAmt + (inAmt * GENESIS_BPS) / 10_000;
        _fundPayer(inAmt * 2);

        // Payer signed at the registered rate; the owner then raises it.
        _setFee(ASSET_ID, 1_000, 0);

        vm.expectRevert(); // Permit2 InvalidAmount: requested > permitted
        masp.deposit(_request(publicIn), _sig(signedTotal), _aux()[0], _aux()[1]);
    }

    /// The escrow digest folds in the rate at submit, so a change afterwards
    /// cannot re-rate a pending deposit. Cancelling with the new rate fails the
    /// digest check; cancelling with the submit-time rate refunds in full.
    function test_escrowedDeposit_keepsItsSubmitTimeRate() public {
        uint64 publicIn = 100;
        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 total = inAmt + (inAmt * GENESIS_BPS) / 10_000;
        _fundPayer(total);

        PubInputs.DepositRequest memory d = _request(publicIn);
        uint256 id = masp.deposit(d, _sig(total), _aux()[0], _aux()[1]);
        uint32 submittedAt = uint32(block.number);

        // Re-rate the asset while the deposit sits in escrow.
        _setFee(ASSET_ID, 1_500, 1_500);
        vm.roll(block.number + masp.cancelDelay());

        PubInputs.FeeNote memory feeNote =
            PubInputs.FeeNote({ feeIn: 0, feeCm: d.feeCm, feeCvDep: [uint256(0), uint256(0)] });

        // The new rate is not what was escrowed.
        vm.prank(PAYER);
        vm.expectRevert(abi.encodeWithSignature("DigestMismatch(uint256)", id));
        masp.cancelDeposit(id, uint48(publicIn), d.outCm, d.cvDep, ASSET_ID, 1_500, PAYER, submittedAt, feeNote);

        // The submit-time rate is, and it refunds everything the payer paid.
        uint256 before = token.balanceOf(PAYER);
        vm.prank(PAYER);
        masp.cancelDeposit(id, uint48(publicIn), d.outCm, d.cvDep, ASSET_ID, GENESIS_BPS, PAYER, submittedAt, feeNote);
        assertEq(token.balanceOf(PAYER) - before, total, "refund at the submit-time rate");
    }

    // --- withdraw leg ------------------------------------------------------

    function test_withdraw_skimsTheAssetsOwnRate() public {
        uint16 rate = 1_000; // 10%
        _setFee(ASSET_ID, 0, rate);
        token.mint(address(masp), 100 * SCALE);

        uint256 gross = SCALE; // publicOut = 1
        uint256 expectedFee = (gross * rate) / 10_000;

        _withdraw();

        assertEq(token.balanceOf(RECIPIENT), gross - expectedFee, "recipient net of the asset rate");
        assertEq(masp.accruedFee(IERC20(address(token))), expectedFee, "accrued at the asset rate");
    }

    function test_withdraw_zeroRate_skimsNothing() public {
        _setFee(ASSET_ID, 0, 0);
        token.mint(address(masp), 100 * SCALE);

        _withdraw();

        assertEq(token.balanceOf(RECIPIENT), SCALE, "full gross to recipient");
        assertEq(masp.accruedFee(IERC20(address(token))), 0, "nothing accrued");
    }

    function test_withdraw_usesGenesisRateWhenUnchanged() public {
        token.mint(address(masp), 100 * SCALE);
        uint256 expectedFee = (SCALE * GENESIS_BPS) / 10_000;

        _withdraw();

        assertEq(token.balanceOf(RECIPIENT), SCALE - expectedFee, "recipient net of the registered rate");
        assertEq(masp.accruedFee(IERC20(address(token))), expectedFee);
    }
}
