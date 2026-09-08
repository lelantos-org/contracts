// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { SymTest } from "halmos-cheatcodes/SymTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { Fees } from "../../src/libs/Fees.sol";
import { UpgradeStorage } from "../../src/UpgradeStorage.sol";

/// Minimal concrete `AssetRegistry`.
///
/// The registry holds no arithmetic and makes no external calls, so nothing
/// here needs mocking — the harness adds an owner, read access to the internal
/// lookups, and a writer for the exit-window slot the fee guard reads.
contract AssetRegistryHarness is AssetRegistry {
    constructor(address owner_) {
        _initOwner(owner_);
    }

    function getAsset(uint64 id) external view returns (AssetEntry memory) {
        return _getAsset(id);
    }

    /// The proxy writes this slot in its own context; the pool only reads it.
    /// Written directly here so the upgrade-window guard can be exercised
    /// without a proxy in the picture.
    function setUpgradePending(address impl) external {
        UpgradeStorage.$().pendingImplementation = impl;
    }
}

/// Symbolic proofs for the asset registry.
///
/// The registry is add-only, and several protocol guarantees rest on that: an
/// id's token and scale are what the escrow digest and every conversion are
/// computed against, and `MASP.addYieldAsset` pairs registration with a
/// permanent venue binding. The proofs below quantify over asset ids rather
/// than sampling them, which is what makes the per-id isolation and
/// add-only claims meaningful — both are statements about mapping keys.
contract AssetRegistrySymbolicTest is GuardAsserts, SymTest {
    AssetRegistryHarness internal reg;

    address internal constant OWNER = address(0xA11CE);
    IERC20 internal constant TOKEN = IERC20(address(0xBEEF));
    uint256 internal constant SCALE = 1e10;

    function setUp() public {
        reg = new AssetRegistryHarness(OWNER);
    }

    /// Registration is accepted for exactly the valid inputs, and rejected for
    /// every invalid one — the acceptance condition is the conjunction of the
    /// four documented guards, no wider and no narrower.
    ///
    /// Both directions matter. A guard that is too strict rejects an asset the
    /// deploy needs and is caught by the reverse implication; one that is too
    /// loose admits a zero token, a zero scale that would make every conversion
    /// divide by nothing, or a rate above the 20% ceiling.
    function check_addAsset_acceptsExactlyValidInputs(
        uint64 id,
        address token,
        uint256 scale,
        uint16 depositBps,
        uint16 withdrawBps
    ) public {
        bool valid = token != address(0) && scale != 0 && scale <= 1e18 && depositBps <= Fees.MAX_FEE_BPS
            && withdrawBps <= Fees.MAX_FEE_BPS;

        vm.prank(OWNER);
        (bool ok,) = address(reg)
            .call(abi.encodeCall(AssetRegistry.addAsset, (id, IERC20(token), scale, depositBps, withdrawBps)));

        assertEq(ok, valid);
    }

    /// A successful registration writes exactly the entry that was asked for,
    /// enabled, for any id.
    function check_addAsset_writesTheRequestedEntry(uint64 id, uint256 scale, uint16 depositBps, uint16 withdrawBps)
        public
    {
        vm.assume(scale != 0 && scale <= 1e18);
        vm.assume(depositBps <= Fees.MAX_FEE_BPS && withdrawBps <= Fees.MAX_FEE_BPS);

        vm.prank(OWNER);
        reg.addAsset(id, TOKEN, scale, depositBps, withdrawBps);

        AssetRegistry.AssetEntry memory a = reg.getAsset(id);
        assertEq(address(a.token), address(TOKEN));
        assertEq(a.scale, scale);
        assertEq(a.depositBps, depositBps);
        assertEq(a.withdrawBps, withdrawBps);
        assertFalse(a.disabled);
    }

    /// An id can be registered once. The second attempt reverts whatever it
    /// carries, so a registration cannot be re-pointed at another token or
    /// re-scaled by re-adding it.
    function check_addAsset_rejectsDuplicateId(uint64 id, address token2, uint256 scale2) public {
        vm.assume(scale2 != 0 && scale2 <= 1e18);

        vm.startPrank(OWNER);
        reg.addAsset(id, TOKEN, SCALE, 0, 0);
        (bool ok,) = address(reg).call(abi.encodeCall(AssetRegistry.addAsset, (id, IERC20(token2), scale2, 0, 0)));
        vm.stopPrank();

        assertFalse(ok);
        assertEq(address(reg.getAsset(id).token), address(TOKEN));
        assertEq(reg.getAsset(id).scale, SCALE);
    }

    /// Add-only, stated over the whole owner-callable surface rather than an
    /// enumerated list of functions: no call the owner can make — the account
    /// with the most authority here — changes a registered id's token or scale.
    ///
    /// This is the property the escrow digest and every unit conversion depend
    /// on. `svm.createCalldata` means a future function that could re-point an
    /// asset is covered by this proof the moment it compiles, rather than when
    /// someone remembers to extend the test.
    function check_registeredAssetIsPermanent(uint64 id) public {
        vm.prank(OWNER);
        reg.addAsset(id, TOKEN, SCALE, 100, 100);

        bytes memory data = svm.createCalldata("AssetRegistryHarness");

        vm.prank(OWNER);
        (bool success,) = address(reg).call(data);
        vm.assume(success);

        AssetRegistry.AssetEntry memory a = reg.getAsset(id);
        assertEq(address(a.token), address(TOKEN));
        assertEq(a.scale, SCALE);
    }

    /// A fee change reaches exactly the id named in the call. The registry has
    /// no pool-wide rate and no unset sentinel precisely so that this holds;
    /// the proof quantifies over both ids, which is where a mapping-key bug
    /// would live.
    function check_setAssetFee_touchesOnlyTheNamedId(uint64 id, uint64 other, uint16 depositBps, uint16 withdrawBps)
        public
    {
        vm.assume(id != other);
        vm.assume(depositBps <= Fees.MAX_FEE_BPS && withdrawBps <= Fees.MAX_FEE_BPS);

        vm.startPrank(OWNER);
        reg.addAsset(id, TOKEN, SCALE, 10, 20);
        reg.addAsset(other, TOKEN, SCALE, 30, 40);
        reg.setAssetFee(id, depositBps, withdrawBps);
        vm.stopPrank();

        AssetRegistry.AssetEntry memory a = reg.getAsset(id);
        assertEq(a.depositBps, depositBps);
        assertEq(a.withdrawBps, withdrawBps);

        AssetRegistry.AssetEntry memory b = reg.getAsset(other);
        assertEq(b.depositBps, 30);
        assertEq(b.withdrawBps, 40);
    }

    /// Disabling one asset leaves every other id enabled.
    function check_setAssetDisabled_touchesOnlyTheNamedId(uint64 id, uint64 other) public {
        vm.assume(id != other);

        vm.startPrank(OWNER);
        reg.addAsset(id, TOKEN, SCALE, 0, 0);
        reg.addAsset(other, TOKEN, SCALE, 0, 0);
        reg.setAssetDisabled(id, true);
        vm.stopPrank();

        assertTrue(reg.getAsset(id).disabled);
        assertFalse(reg.getAsset(other).disabled);
    }

    /// The withdraw rate can only fall while an upgrade is queued.
    ///
    /// The withdraw leg is read at execution rather than snapshotted, so
    /// without this an exit fee could be raised against the holders leaving
    /// during the very window the delay exists to give them. The deposit leg is
    /// unrestricted by design — it is folded into the escrow digest at submit —
    /// and this proves the asymmetry rather than assuming it.
    function check_setAssetFee_withdrawRateCannotRiseDuringUpgradeWindow(
        uint16 startWithdraw,
        uint16 newWithdraw,
        uint16 newDeposit,
        address pendingImpl
    ) public {
        vm.assume(startWithdraw <= Fees.MAX_FEE_BPS && newWithdraw <= Fees.MAX_FEE_BPS);
        vm.assume(newDeposit <= Fees.MAX_FEE_BPS);
        vm.assume(pendingImpl != address(0));

        vm.prank(OWNER);
        reg.addAsset(1, TOKEN, SCALE, 0, startWithdraw);
        reg.setUpgradePending(pendingImpl);

        vm.prank(OWNER);
        (bool ok,) = address(reg).call(abi.encodeCall(AssetRegistry.setAssetFee, (1, newDeposit, newWithdraw)));

        assertEq(ok, newWithdraw <= startWithdraw);
        assertEq(reg.getAsset(1).withdrawBps, ok ? newWithdraw : startWithdraw);
    }
}
