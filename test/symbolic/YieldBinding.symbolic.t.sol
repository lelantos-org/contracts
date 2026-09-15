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
import { ExitTerms } from "../../src/libs/ExitTerms.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MockAllowanceTransfer } from "./mocks/MockAllowanceTransfer.sol";
import { MockYieldVenue, MockVaultAsset } from "./mocks/MockYieldVenue.sol";
import { deployPoolUniform, singleAsset } from "../utils/PoolDeployer.sol";

/// Symbolic proofs for the venue binding and the yield surface's access
/// control.
///
/// A venue binding is permanent: `_initYieldAsset` is the only writer of
/// `params[id].venue`, it is reached only from `addYieldAsset`, and the registry
/// is add-only, so the venue is written at most once per id and there is no
/// `setVenue`. Replacing a venue therefore requires registering a new asset id,
/// with a public exit and re-entry for its holders.
///
/// Index behaviour is out of scope: every unit conversion in `YieldOps` uses
/// `Math.mulDiv`, a product of symbolic values under a division that the solvers
/// do not finish at any argument width. Yield accounting and rounding are covered
/// in `test/yield/`. The binding and its authorization involve no arithmetic.
///
/// Mocked: the venue and its vault (`MockYieldVenue`), which `initAsset` probes
/// through three view calls only; Permit2; both Groth16 verifiers.
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
    /// A depositor chooses custody by choosing an asset id, which is meaningful
    /// only if the id's venue cannot change. `_initYieldAsset` is the sole writer
    /// and is reached only from `addYieldAsset`, so rejecting re-registration
    /// makes the binding permanent.
    ///
    /// Uses enumerated owner calls rather than `svm.createCalldata`: quantifying
    /// over the pool's full external surface includes `transfer` and `withdraw`,
    /// which pass validation into `PubInputs.compress` and do not terminate.
    /// `check_ownerConfigurationCannotMoveAVenue` enumerates the owner
    /// configuration calls; a new function that writes yield or registry state
    /// must be added there by hand.
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

    /// `setYieldParams`, `setHalted`, `setAssetDisabled` and the commit of a
    /// queued rate raise do not move a bound venue. `bufferBps` shifts the
    /// idle/lent split and `perfBps` the treasury's cut, neither moving
    /// principal between protocols; `halted` stops new supply without clearing
    /// the binding.
    function check_ownerConfigurationCannotMoveAVenue(uint16 bufferBps, uint16 perfBps, bool halted) public {
        (bool added,) = _addYieldAsset(YIELD_ID, address(venue));
        assertTrue(added);

        vm.startPrank(OWNER);
        address(masp).call(abi.encodeCall(YieldIndex.setYieldParams, (YIELD_ID, bufferBps, perfBps)));
        address(masp).call(abi.encodeCall(YieldIndex.setHalted, (YIELD_ID, halted)));
        address(masp).call(abi.encodeCall(AssetRegistry.setAssetDisabled, (YIELD_ID, true)));
        vm.stopPrank();

        // A raised `perfBps` is only queued; land it too.
        vm.warp(block.timestamp + ExitTerms.DELAY);
        address(masp).call(abi.encodeCall(MASP.commitExitTerms, (YIELD_ID)));

        assertEq(masp.yieldState(YIELD_ID).venue, address(venue), "venue unchanged");
        assertTrue(masp.isYieldAsset(YIELD_ID));
    }

    /// A plain asset cannot acquire a venue after registration: the registry is
    /// add-only, so re-registering its id reverts before any venue is written.
    ///
    /// Opting out of yield is as durable as opting in: the plain id for a token
    /// is unlent custody for its lifetime.
    function check_plainAssetCannotGainAVenueLater() public {
        (bool ok,) = _addYieldAsset(PLAIN_ID, address(venue));

        assertFalse(ok, "id already registered");
        assertFalse(masp.isYieldAsset(PLAIN_ID), "still unlent custody");
    }

    // --- binding validation ------------------------------------------------

    /// A venue must be pinned to this pool; otherwise it would hold this pool's
    /// principal while answering to another pool.
    function check_addYieldAsset_rejectsVenuePinnedElsewhere(address otherPool) public {
        vm.assume(otherPool != address(masp));

        MockYieldVenue foreign = new MockYieldVenue(otherPool, address(new MockVaultAsset(address(token))));
        (bool ok, bytes memory ret) = _addYieldAsset(YIELD_ID, address(foreign));

        _assertRejected(ok, ret, YieldOps.VenueNotPinned.selector);
        assertFalse(masp.isYieldAsset(YIELD_ID), "nothing bound on a rejected registration");
    }

    /// The venue's vault must hold the asset being registered. A mismatch would
    /// supply one token's deposits into a vault denominated in another, and since
    /// the binding is permanent the error would be unrecoverable for that id.
    function check_addYieldAsset_rejectsVaultHoldingAnotherAsset(address vaultAsset) public {
        vm.assume(vaultAsset != address(token));

        MockYieldVenue wrong = new MockYieldVenue(address(masp), address(new MockVaultAsset(vaultAsset)));
        (bool ok, bytes memory ret) = _addYieldAsset(YIELD_ID, address(wrong));

        _assertRejected(ok, ret, YieldOps.VenueAssetMismatch.selector);
        assertFalse(masp.isYieldAsset(YIELD_ID));
    }

    /// A venue backs at most one id: once bound, registering it under any other
    /// id is rejected `VenueAlreadyBound`, and that id stays unregistered. Two
    /// ids on one venue would both count its position in `gross`.
    function check_addYieldAsset_rejectsVenueBoundToAnotherId(uint64 first, uint64 second) public {
        vm.assume(first != PLAIN_ID && second != PLAIN_ID && first != second);

        (bool added,) = _addYieldAsset(first, address(venue));
        assertTrue(added, "venue bound");

        (bool ok, bytes memory ret) = _addYieldAsset(second, address(venue));

        _assertRejected(ok, ret, YieldOps.VenueAlreadyBound.selector);
        assertFalse(masp.isYieldAsset(second), "second id not bound");
    }

    /// A zero venue is rejected, so the yield entry point cannot register a plain
    /// asset.
    function check_addYieldAsset_rejectsZeroVenue() public {
        (bool ok, bytes memory ret) = _addYieldAsset(YIELD_ID, address(0));

        _assertRejected(ok, ret, YieldOps.VenueZero.selector);
    }

    /// The buffer split and performance fee are accepted for exactly their
    /// ranges: the buffer is a fraction of gross (at most `BPS_DENOMINATOR`), and
    /// the performance fee has the same 20% ceiling as every other rate.
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

    /// Registering a yield asset rejects every non-owner caller; it binds custody
    /// permanently.
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
    /// leaving the binding in place, so a permissionless halt would allow denial
    /// of yield; the exit path stays open either way.
    function check_setHalted_isOwnerOnly(address caller, bool halted) public {
        vm.assume(caller != OWNER);
        (bool added,) = _addYieldAsset(YIELD_ID, address(venue));
        assertTrue(added);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(masp).call(abi.encodeCall(YieldIndex.setHalted, (YIELD_ID, halted)));

        _assertRejected(ok, ret, OwnableInit.OwnableUnauthorizedAccount.selector);
        assertFalse(masp.yieldState(YIELD_ID).halted);
    }

    /// Updating the buffer split and performance fee is owner-only.
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
