// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { YieldOps } from "../../src/yield/YieldOps.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { OwnableInit } from "../../src/OwnableInit.sol";
import { Fees } from "../../src/libs/Fees.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MockAllowanceTransfer } from "./mocks/MockAllowanceTransfer.sol";
import { MockYieldVenue, MockVaultAsset } from "./mocks/MockYieldVenue.sol";
import { deployPoolUniform, singleAsset } from "../utils/PoolDeployer.sol";

/// Symbolic proofs for the venue binding and the yield surface's access
/// control.
///
/// A venue binding is permanent by construction: `_initYieldAsset` is the only
/// path that writes one, it is reached only from `addYieldAsset`, and the
/// registry underneath is add-only, so `params[id].venue` is written at most
/// once per id and there is no `setVenue`. That claim is what the proofs below
/// check — replacing a venue is meant to require registering a new asset id, at
/// the cost of a public exit and re-entry for its holders, and this is what
/// makes that cost unavoidable.
///
/// What is *not* here: anything about the index itself. Every unit conversion
/// in `YieldOps` runs through `Math.mulDiv`, a symbolic-times-symbolic product
/// under a division, which no solver here finishes at any argument width. The
/// yield accounting and rounding properties stay with `test/yield/`. The
/// binding and the authorization around it carry no arithmetic at all, which is
/// exactly why they are affordable.
///
/// Mocked: the venue and its vault (`MockYieldVenue`), which `initAsset` probes
/// through three view calls and nothing else; Permit2; both Groth16 verifiers.
contract YieldBindingSymbolicTest is GuardAsserts {
    uint64 internal constant PLAIN_ID = 1;
    uint64 internal constant YIELD_ID = 2;
    uint256 internal constant SCALE = 1e10;
    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);

    MASP internal masp;
    MockERC20 internal token;
    MockYieldVenue internal venue;

    function setUp() public {
        token = new MockERC20("M", "M", 18);
        MockAllowanceTransfer permit2 = new MockAllowanceTransfer();
        MockBatchVerifier spendVerifier = new MockBatchVerifier();
        spendVerifier.setResult(true);
        MockBatchVerifier tubVerifier = new MockBatchVerifier();

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), PLAIN_ID, SCALE);

        masp = deployPoolUniform(
            IVerifier(address(tubVerifier)),
            IBatchVerifier(address(spendVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            0,
            TREASURY,
            OWNER
        );

        venue = new MockYieldVenue(address(masp), address(new MockVaultAsset(address(token))));
    }

    function _addYieldAsset(uint64 id, address venue_) internal returns (bool ok, bytes memory ret) {
        vm.prank(OWNER);
        (ok, ret) = address(masp)
            .call(abi.encodeCall(MASP.addYieldAsset, (id, IERC20(address(token)), SCALE, 0, 0, venue_, 0, 0)));
    }

    // --- binding permanence ------------------------------------------------

    /// Once bound, an asset's venue never changes: a second registration of the
    /// id is rejected by the add-only registry before any venue is written, for
    /// every id and every venue offered.
    ///
    /// This is the property that makes yield opt-in meaningful. A depositor
    /// chooses custody by picking an asset id, and that choice only binds if the
    /// id's venue cannot be re-pointed underneath them. `_initYieldAsset` is the
    /// sole writer and is reached only from `addYieldAsset`, so rejecting the
    /// re-registration is what makes the binding permanent — replacing a venue
    /// has to mean a new id, and a public exit and re-entry for its holders.
    ///
    /// Stated over an enumerated set of owner calls rather than
    /// `svm.createCalldata`, deliberately. Quantifying over the pool's whole
    /// external surface also enumerates `transfer` and `withdraw`, and with the
    /// verifier mocked to accept, those *succeed* into `PubInputs.compress` —
    /// the proof does not time out, it fails to terminate. The enumeration below
    /// covers every function that writes yield or registry state; a new one has
    /// to be added here by hand, which is the cost of the reshape.
    function check_yieldVenueBindingIsPermanent(uint64 id, address otherVenue) public {
        vm.assume(id != PLAIN_ID);

        (bool added,) = _addYieldAsset(id, address(venue));
        assertTrue(added, "venue bound");

        // A second registration of the same id, pointing anywhere else.
        (bool rebound,) = _addYieldAsset(id, otherVenue);
        assertFalse(rebound, "id cannot be re-registered");

        assertEq(masp.yieldState(id).venue, address(venue), "venue unchanged");
        assertTrue(masp.isYieldAsset(id), "asset stays a yield asset");
    }

    /// None of the owner's configuration calls moves a bound venue. `bufferBps`
    /// shifts the idle/lent split and `perfBps` the treasury's cut; neither is
    /// allowed to move principal between protocols, and `halted` stops new
    /// supply without clearing the binding.
    function check_ownerConfigurationCannotMoveAVenue(uint16 bufferBps, uint16 perfBps, bool halted) public {
        (bool added,) = _addYieldAsset(YIELD_ID, address(venue));
        assertTrue(added);

        vm.startPrank(OWNER);
        address(masp).call(abi.encodeCall(YieldIndex.setYieldParams, (YIELD_ID, bufferBps, perfBps)));
        address(masp).call(abi.encodeCall(YieldIndex.setHalted, (YIELD_ID, halted)));
        address(masp).call(abi.encodeCall(AssetRegistry.setAssetDisabled, (YIELD_ID, true)));
        vm.stopPrank();

        assertEq(masp.yieldState(YIELD_ID).venue, address(venue), "venue unchanged");
        assertTrue(masp.isYieldAsset(YIELD_ID));
    }

    /// A plain asset cannot acquire a venue after registration either: the
    /// registry is add-only, so the second registration of its id reverts before
    /// any venue is written.
    ///
    /// Opting out of yield has to be as durable as opting in — the plain id for
    /// a token is unlent custody, and a depositor who chose it must keep it.
    function check_plainAssetCannotGainAVenueLater() public {
        (bool ok,) = _addYieldAsset(PLAIN_ID, address(venue));

        assertFalse(ok, "id already registered");
        assertFalse(masp.isYieldAsset(PLAIN_ID), "still unlent custody");
    }

    // --- binding validation ------------------------------------------------

    /// A venue must be pinned to this pool. An unpinned one would take custody
    /// of this pool's principal while answering to another.
    function check_addYieldAsset_rejectsVenuePinnedElsewhere(address otherPool) public {
        vm.assume(otherPool != address(masp));

        MockYieldVenue foreign = new MockYieldVenue(otherPool, address(new MockVaultAsset(address(token))));
        (bool ok, bytes memory ret) = _addYieldAsset(YIELD_ID, address(foreign));

        _assertRejected(ok, ret, YieldOps.VenueNotPinned.selector);
        assertFalse(masp.isYieldAsset(YIELD_ID), "nothing bound on a rejected registration");
    }

    /// The venue's vault must hold the asset being registered. A mismatch would
    /// supply one token's deposits into a vault denominated in another, and the
    /// binding is permanent, so the error would be unrecoverable for that id.
    function check_addYieldAsset_rejectsVaultHoldingAnotherAsset(address vaultAsset) public {
        vm.assume(vaultAsset != address(token));

        MockYieldVenue wrong = new MockYieldVenue(address(masp), address(new MockVaultAsset(vaultAsset)));
        (bool ok, bytes memory ret) = _addYieldAsset(YIELD_ID, address(wrong));

        _assertRejected(ok, ret, YieldOps.VenueAssetMismatch.selector);
        assertFalse(masp.isYieldAsset(YIELD_ID));
    }

    /// A zero venue is rejected rather than silently registering a plain asset
    /// through the yield entry point.
    function check_addYieldAsset_rejectsZeroVenue() public {
        (bool ok, bytes memory ret) = _addYieldAsset(YIELD_ID, address(0));

        _assertRejected(ok, ret, YieldOps.VenueZero.selector);
    }

    /// The buffer split and the performance fee are accepted for exactly their
    /// documented ranges: a buffer is a fraction of gross, and the performance
    /// fee is capped at the same 20% ceiling as every other rate.
    function check_addYieldAsset_acceptsExactlyValidParams(uint16 bufferBps, uint16 perfBps) public {
        vm.prank(OWNER);
        (bool ok,) = address(masp)
            .call(
                abi.encodeCall(
                    MASP.addYieldAsset,
                    (YIELD_ID, IERC20(address(token)), SCALE, 0, 0, address(venue), bufferBps, perfBps)
                )
            );

        assertEq(ok, bufferBps <= Fees.BPS_DENOMINATOR && perfBps <= Fees.MAX_FEE_BPS);
    }

    // --- authorization -----------------------------------------------------

    /// Registering a yield asset is owner-only, for every other caller. It binds
    /// custody permanently, so it is the most consequential call on the pool.
    function check_addYieldAsset_isOwnerOnly(address caller) public {
        vm.assume(caller != OWNER);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(masp)
            .call(
                abi.encodeCall(
                    MASP.addYieldAsset, (YIELD_ID, IERC20(address(token)), SCALE, 0, 0, address(venue), 0, 0)
                )
            );

        _assertRejected(ok, ret, OwnableInit.OwnableUnauthorizedAccount.selector);
        assertFalse(masp.isYieldAsset(YIELD_ID));
    }

    /// Halting supply to a venue is owner-only. `halted` stops new supply while
    /// leaving the binding in place, so an open one would be a denial of yield;
    /// the exit path stays open either way.
    function check_setHalted_isOwnerOnly(address caller, bool halted) public {
        vm.assume(caller != OWNER);
        (bool added,) = _addYieldAsset(YIELD_ID, address(venue));
        assertTrue(added);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(masp).call(abi.encodeCall(YieldIndex.setHalted, (YIELD_ID, halted)));

        _assertRejected(ok, ret, OwnableInit.OwnableUnauthorizedAccount.selector);
        assertFalse(masp.yieldState(YIELD_ID).halted);
    }

    /// Retuning the buffer split and performance fee is owner-only.
    function check_setYieldParams_isOwnerOnly(address caller, uint16 bufferBps, uint16 perfBps) public {
        vm.assume(caller != OWNER);
        (bool added,) = _addYieldAsset(YIELD_ID, address(venue));
        assertTrue(added);

        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(masp).call(abi.encodeCall(YieldIndex.setYieldParams, (YIELD_ID, bufferBps, perfBps)));

        _assertRejected(ok, ret, OwnableInit.OwnableUnauthorizedAccount.selector);
    }
}
