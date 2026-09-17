// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { YieldOps } from "../../src/yield/YieldOps.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";

import { ERC4626VenueStub } from "../mocks/ERC4626VenueStub.sol";
import { YieldTestBase } from "../utils/YieldTestBase.sol";

/// Behaviour of the pool-managed yield index.
///
/// Performance-fee tests live in `YieldIndex.perfFee.t.sol` and venue-liveness
/// tests in `YieldIndex.liveness.t.sol`.
contract YieldIndexTest is YieldTestBase {
    uint64 internal constant N = 1_000_000; // units; fee at 25bps is 2_500

    // ============== Shielding ================================================

    /// An empty asset has no ratio yet, so one unit is worth exactly `scale`
    /// and the index reads `RAY`, which fixes the first deposit's price.
    function test_firstDeposit_indexIsRay_andPullIsExact() public {
        (, uint256 pulled) = _deposit(YIELD_ID, N, 0x101);
        uint256 nFee = (uint256(N) * FEE_BPS) / 10_000;
        uint256 expected = (uint256(N) + nFee) * SCALE;

        assertEq(pulled, expected, "pull is (publicIn + fee) * scale");
        assertEq(masp.index(YIELD_ID), RAY, "index starts at RAY");
        assertEq(_supply(YIELD_ID), uint256(N) + nFee, "fee units held as principal until flush");
    }

    /// Everything above the buffer target is supplied to the venue at submit,
    /// not at flush: a note minted at `n` must be backed by `n` at the index at
    /// which the pool received it.
    function test_deposit_fundsVenueDownToBuffer() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 g = _gross(YIELD_ID);
        assertEq(_idle(YIELD_ID), (g * BUFFER_BPS) / 10_000, "idle held at the buffer target");
        assertGt(vault.balanceOf(address(venue)), 0, "remainder supplied to the venue");
    }

    // ============== Earning ==================================================

    /// Units stay fixed while their value grows.
    function test_earn_thenWithdraw_paysMoreThanWasDeposited() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 perUnitBefore = masp.index(YIELD_ID);

        _earn(1_000 * SCALE);
        assertGt(masp.index(YIELD_ID), perUnitBefore, "index rises with the venue");

        uint256 recipientBefore = token.balanceOf(RECIPIENT);
        _withdraw(YIELD_ID, N, 0x1111);
        uint256 paid = token.balanceOf(RECIPIENT) - recipientBefore;

        uint256 nFee = (uint256(N) * FEE_BPS) / 10_000;
        assertGt(paid, (uint256(N) - nFee) * SCALE, "payout exceeds the flat-rate value of the same units");
    }

    /// `publicOut == publicIn` across a round trip that earned. The circuit
    /// never sees the index, so the published integers are unchanged.
    function test_unitsAreStableAcrossEarning() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 unitsAfterDeposit = _supply(YIELD_ID);
        _earn(5_000 * SCALE);
        assertEq(_supply(YIELD_ID), unitsAfterDeposit, "earning mints no units to holders");
    }

    // ============== Zero backing ============================================

    /// Loses everything the asset holds while units are outstanding: a zero
    /// buffer keeps nothing idle, and the venue's vault is wiped.
    function _wipeBacking() internal {
        vault.lose(vault.totalAssetsHeld());
        assertEq(_idle(YIELD_ID), 0, "nothing idle");
        assertEq(_gross(YIELD_ID), 0, "nothing backs the units");
        assertGt(_supply(YIELD_ID), 0, "units still outstanding");
    }

    function _unbufferedDeposit() internal returns (uint256 id) {
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, 0, PERF_BPS);
        (id,) = _deposit(YIELD_ID, N, 0x101);
    }

    /// A shield against zero backing would price every unit at zero and mint
    /// units for free against any later recovery.
    function test_revert_NoBacking_depositAtZeroGross() public {
        _unbufferedDeposit();
        _wipeBacking();

        vm.expectRevert(abi.encodeWithSelector(YieldOps.NoBacking.selector, YIELD_ID));
        this.attemptDeposit(YIELD_ID, N, 0x301);
    }

    /// An unshield against zero backing would burn the note's claim for
    /// nothing, forfeiting its share of any recovery.
    function test_revert_NoBacking_withdrawAtZeroGross() public {
        _unbufferedDeposit();
        _wipeBacking();

        vm.expectRevert(abi.encodeWithSelector(YieldOps.NoBacking.selector, YIELD_ID));
        this.attemptWithdraw(YIELD_ID, N / 2, 0x6666);
        assertFalse(masp.spent(bytes32(uint256(0x6666))), "nullifier untouched by the reverted spend");
    }

    /// A cancel against zero backing would burn the escrow's units and refund
    /// nothing; it is refused and the escrow survives until the asset is backed.
    function test_revert_NoBacking_cancelAtZeroGross() public {
        uint32 submittedAt = uint32(vm.getBlockNumber());
        uint256 id = _unbufferedDeposit();
        _wipeBacking();
        vm.roll(block.number + 7_201);

        vm.expectRevert(abi.encodeWithSelector(YieldOps.NoBacking.selector, YIELD_ID));
        this.attemptCancel(id, N, 0x101, submittedAt);
        assertTrue(masp.escrowed(id) != bytes32(0), "escrow survives the refused cancel");
    }

    /// External so `vm.expectRevert` has a call boundary to catch.
    function attemptDeposit(uint64 id, uint64 publicIn, uint256 seed) external {
        _deposit(id, publicIn, seed);
    }

    /// External so `vm.expectRevert` has a call boundary to catch.
    function attemptCancel(uint256 id, uint64 publicIn, uint256 seed, uint32 submittedAt) external {
        masp.cancelDeposit(
            id,
            uint48(publicIn),
            bytes32(seed),
            [uint256(0), 0],
            YIELD_ID,
            FEE_BPS,
            payer,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(seed + 1), feeCvDep: [uint256(0), 0] })
        );
    }

    // ============== Immutability =============================================

    /// The binding is permanent because the registry is add-only and there is
    /// no `setVenue`.
    function test_venueBindingIsImmutable() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.DuplicateAsset.selector, YIELD_ID));
        masp.addYieldAsset(
            YIELD_ID, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(venue), BUFFER_BPS, PERF_BPS
        );
    }

    /// A venue pinned to some other pool cannot be bound here.
    function test_addYieldAsset_rejectsUnpinnedVenue() public {
        ERC4626VenueStub bad = new ERC4626VenueStub(address(0xdead), address(vault));
        vm.prank(OWNER);
        vm.expectRevert(YieldOps.VenueNotPinned.selector);
        masp.addYieldAsset(77, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(bad), BUFFER_BPS, PERF_BPS);
    }

    /// A venue already backing one id cannot back another. Both ids would count
    /// its whole position in `gross`, so a deposit into one would raise the
    /// other's index.
    function test_revert_VenueAlreadyBound_secondIdSameVenue() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(YieldOps.VenueAlreadyBound.selector, address(venue)));
        masp.addYieldAsset(77, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(venue), BUFFER_BPS, PERF_BPS);

        assertFalse(masp.isYieldAsset(77), "nothing bound");
        // The registry write reverted with the binding.
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(77)));
        masp.asset(77);
    }

    // ============== Isolation ================================================

    /// Two ids over one ERC-20: the plain id is ordinary custody and is
    /// untouched by anything the venue does.
    function test_plainIdIsUnaffectedByTheYieldId() public {
        _deposit(PLAIN_ID, N, 0x201);

        _deposit(YIELD_ID, N, 0x301);
        _earn(1_000 * SCALE);
        vault.lose(500 * SCALE);

        assertFalse(masp.isYieldAsset(PLAIN_ID), "plain id carries no venue");
        uint256 before = token.balanceOf(RECIPIENT);
        _withdraw(PLAIN_ID, N, 0x4444);
        uint256 paid = token.balanceOf(RECIPIENT) - before;
        uint256 outAmt = uint256(N) * SCALE;
        assertEq(paid, outAmt - (outAmt * FEE_BPS) / 10_000, "flat-rate payout, unmoved by the venue");
    }

    /// A donation to the pool cannot move the index, because `idle` is tracked
    /// rather than read from `balanceOf`; this also lets two ids share a token.
    function test_donationToPoolCannotMoveTheIndex() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 idxBefore = masp.index(YIELD_ID);
        token.mint(address(masp), 10_000 * SCALE);
        assertEq(masp.index(YIELD_ID), idxBefore, "index is blind to unattributed balance");
    }

    /// A donation to the *venue* is indistinguishable from interest and is
    /// treated as such.
    function test_donationToVenueIsTreatedAsYield() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 idxBefore = masp.index(YIELD_ID);
        _earn(1_000 * SCALE);
        assertGt(masp.index(YIELD_ID), idxBefore, "venue growth reaches holders");
    }

    // ============== Withdraw-only retirement =================================

    /// `setAssetDisabled` stops new deposits and nothing else. `transfer` in
    /// particular must keep working, or a holder cannot decompose an odd note
    /// into ladder denominations before exiting.
    function test_disabledYieldAsset_blocksDepositsButNotExits() public {
        _deposit(YIELD_ID, N, 0x101);
        vm.prank(OWNER);
        masp.setAssetDisabled(YIELD_ID, true);

        token.mint(payer, type(uint128).max);
        _allow(type(uint160).max);
        PubInputs.DepositRequest memory d = _request(YIELD_ID, N, 0, 0x401);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetDisabled.selector, YIELD_ID));
        masp.depositAuthorized(d, SpendFixture.validAux()[0], SpendFixture.validAux()[1]);

        uint256 before = token.balanceOf(RECIPIENT);
        _withdraw(YIELD_ID, N / 2, 0x5555);
        assertGt(token.balanceOf(RECIPIENT) - before, 0, "holders can still exit");
    }
}
