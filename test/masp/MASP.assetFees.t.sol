// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { MockPoolTestBase } from "../utils/MockPoolTestBase.sol";
import { twoAssets } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";

/// Per-asset deposit and withdraw rates. There is no pool-wide rate and no
/// inheritance: every asset stores its own pair, and a stored `0` means 0.
///
/// Both verifiers are mocked to accept any proof; the subject is rate
/// selection and scope, not circuit correctness.
///
/// A fee change reaches exactly the ids named in the call. No setter can
/// re-rate an asset the owner did not name.
contract MASPAssetFeesTest is MockPoolTestBase {
    uint64 internal constant OTHER_ID = 2;
    uint16 internal constant GENESIS_BPS = 25;
    uint16 internal constant MAX_BPS = 2_000;

    address internal constant PAYER = address(0xBEEF);

    MockERC20 internal other;

    function setUp() public {
        token = new MockERC20("M", "M", 18);
        other = new MockERC20("N", "N", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            twoAssets(IERC20(address(token)), ASSET_ID, IERC20(address(other)), OTHER_ID, SCALE);

        _deployMockPool(ids, tokens, scales, GENESIS_BPS, TREASURY, OWNER);

        Stubs.acceptAllProofs(tub, bv);
        // The subject here is the amount pulled, not the signature.
        Stubs.installPermissiveERC1271(PAYER);
    }

    // --- helpers -----------------------------------------------------------

    /// Sets both rates and, if the withdraw rate rose, waits out the notice and
    /// commits it. The tests using this concern a rate once it is in force; the
    /// queue itself is covered in `MASP.upgrade.t.sol` and below.
    function _setFee(uint64 id, uint16 dep, uint16 wit) internal {
        (, uint16 live) = masp.assetFees(id);
        vm.prank(OWNER);
        masp.setAssetFee(id, dep, wit);
        if (wit > live) _commitRaise(id);
    }

    function _commitRaise(uint64 id) internal {
        vm.warp(vm.getBlockTimestamp() + ExitTerms.DELAY);
        masp.commitExitTerms(id);
    }

    function _request(uint64 publicIn) internal view returns (PubInputs.DepositRequest memory) {
        return DepositFixture.request(ASSET_ID, publicIn, PAYER, RECIPIENT, bytes32(uint256(0xdead)));
    }

    function _sig(uint256 maxTotal) internal pure returns (MASP.Permit2Sig memory) {
        return DepositFixture.sig(0, maxTotal, 0);
    }

    function _fundPayer(uint256 amount) internal {
        token.mint(PAYER, amount);
        vm.prank(PAYER);
        token.approve(address(permit2), type(uint256).max);
    }

    /// `publicOut = 1`, i.e. `SCALE` base units gross. Repeatable: nullifiers,
    /// commitments and the tree position follow the leaves already committed.
    function _withdraw() internal {
        uint64 cc = masp.committedCount();
        PubInputs.Transact memory pi =
            _transact(PAYER, RELAYER, 0x1111 + uint256(cc) * 0x100, 0x3333 + uint256(cc) * 0x100);
        pi.publicAssetId = ASSET_ID;
        pi.publicOut = 1;
        PubInputs.SpendTree memory tpi =
            SpendFixture.spendTree(bytes32(uint256(0xABCD) + cc), cc, uint8(masp.rootIndex()));

        vm.prank(RELAYER);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    // --- resolution --------------------------------------------------------

    /// The constructor's rate is a starting value written into each genesis
    /// entry, not a fallback consulted later.
    function test_genesisRateIsWrittenToBothLegs() public view {
        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, GENESIS_BPS);
        assertEq(wit, GENESIS_BPS);
    }

    /// Legs are set independently, e.g. free to enter and charged on exit.
    function test_setAssetFee_setsLegsIndependently() public {
        _setFee(ASSET_ID, 0, 50);
        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, 0, "deposit free");
        assertEq(wit, 50, "withdraw charged");
    }

    /// A rate change affects exactly one id.
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

    /// The ceiling is checked when a rate is set, whether the withdraw rate is
    /// applied or queued, so a committed raise is always within it.
    function testFuzz_setAssetFee_ceilingHolds(uint16 dep, uint16 wit) public {
        if (dep > MAX_BPS || wit > MAX_BPS) {
            vm.prank(OWNER);
            vm.expectRevert(AssetRegistry.AssetFeeTooHigh.selector);
            masp.setAssetFee(ASSET_ID, dep, wit);
        } else {
            _setFee(ASSET_ID, dep, wit);
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
    /// fires on each. `AssetRegistered` carries no rates.
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
        masp.deposit(_request(publicIn), _sig(expected), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);

        assertEq(token.balanceOf(address(masp)) - before, expected, "pulled at the asset rate");
    }

    function test_deposit_zeroRate_chargesPrincipalOnly() public {
        _setFee(ASSET_ID, 0, 0);

        uint64 publicIn = 100;
        uint256 inAmt = uint256(publicIn) * SCALE;
        _fundPayer(inAmt);

        uint256 before = token.balanceOf(address(masp));
        masp.deposit(_request(publicIn), _sig(inAmt), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);

        assertEq(token.balanceOf(address(masp)) - before, inAmt, "no fee on top");
    }

    /// The deposit leg is protected by the signed ceiling: raising the rate
    /// after the payer signed does not make them pay more; the pull exceeds
    /// `maxTotal` and Permit2 refuses. The withdraw leg has no equivalent (see
    /// `_unshieldLeg`).
    function test_deposit_signedCeilingBoundsALaterRateRaise() public {
        uint64 publicIn = 100;
        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 signedTotal = inAmt + (inAmt * GENESIS_BPS) / 10_000;
        _fundPayer(inAmt * 2);

        // Payer signed at the registered rate; the owner then raises it.
        _setFee(ASSET_ID, 1_000, 0);

        vm.expectRevert(); // Permit2 InvalidAmount: requested > permitted
        masp.deposit(_request(publicIn), _sig(signedTotal), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
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
        uint256 id = masp.deposit(d, _sig(total), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
        uint32 submittedAt = uint32(block.number);

        // Re-rates the asset while the deposit is in escrow.
        _setFee(ASSET_ID, 1_500, 1_500);
        vm.roll(block.number + masp.cancelDelay());

        PubInputs.FeeNote memory feeNote =
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: d.feeCm, feeCvDep: [uint256(0), uint256(0)] });

        // The new rate is not what was escrowed.
        vm.prank(PAYER);
        vm.expectRevert(abi.encodeWithSignature("DigestMismatch(uint256)", id));
        masp.cancelDeposit(id, uint48(publicIn), d.outCm, d.cvDep, ASSET_ID, 1_500, PAYER, submittedAt, feeNote);

        // The submit-time rate matches and refunds everything the payer paid.
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

    /// A queued raise does not reach a withdrawal: until the commit every exit
    /// pays the live rate, and afterwards the raised one. This is the notice
    /// holders get to leave at the old rate.
    function test_withdraw_paysTheLiveRateUntilARaiseIsCommitted() public {
        token.mint(address(masp), 100 * SCALE);
        uint16 raised = 1_000;
        vm.prank(OWNER);
        masp.setAssetFee(ASSET_ID, GENESIS_BPS, raised);

        vm.warp(vm.getBlockTimestamp() + ExitTerms.DELAY - 1);
        _withdraw();
        uint256 atLive = (SCALE * GENESIS_BPS) / 10_000;
        assertEq(token.balanceOf(RECIPIENT), SCALE - atLive, "queued raise reached an exit");

        _commitRaise(ASSET_ID);
        _withdraw();
        uint256 atRaised = (SCALE * raised) / 10_000;
        assertEq(token.balanceOf(RECIPIENT), 2 * SCALE - atLive - atRaised, "committed raise not charged");
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
