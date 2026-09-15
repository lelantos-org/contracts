// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { SymTest } from "halmos-cheatcodes/SymTest.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ProtocolAdmin } from "../../src/governance/ProtocolAdmin.sol";
import { MockAdminTarget, MockSuccessorAdmin } from "./mocks/MockAdminTargets.sol";

/// Symbolic proofs for the contract that owns the pool once governance is live.
///
/// `ProtocolAdmin` provides two guarantees:
///
/// 1. **Ownership and the proxy admin leave only through `migrateAdmin`.**
///    Every pool admin function is `onlyOwner`, so moving ownership out of this
///    contract permanently disables asset registration, rate changes and
///    guardian response; moving the proxy admin alone splits upgrade authority
///    from ownership. `execute` is an arbitrary-call primitive whose selector
///    comparisons are the only check preventing either.
/// 2. **The guardian's switches are one-way.** The guardian may close things
///    within the timelock delay but never open them, so a compromised guardian
///    key affects availability, not custody.
///
/// Both quantify over every calldata and every caller. The selector guard is a
/// two-value comparison in a 2^32 space that a fuzzer sampling `bytes calldata`
/// almost never hits. The tail beyond the selector is also symbolic, so a guard
/// matching on more than the leading four bytes would fail.
///
/// Reachable code is comparisons and mapping writes, with no arithmetic and no
/// hashing beyond compile-time role ids.
///
/// The pool and wrapper are `MockAdminTarget`: `svm.createCalldata` against a
/// real `MASP` does not terminate (see `README.md`), and none of these properties
/// depend on what the pool does with the forwarded call.
contract ProtocolAdminSymbolicTest is GuardAsserts, SymTest {
    ProtocolAdmin internal admin;
    MockAdminTarget internal pool;
    MockAdminTarget internal wrapper;

    /// The Timelock, in production.
    address internal constant GOV = address(0x60F);
    address internal constant GUARDIAN = address(0x6A4D);

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal GUARDIAN_ROLE;

    /// Length of the symbolic calldata the `execute` proofs quantify over: a
    /// four-byte selector plus one argument word. Every selector `MockAdminTarget`
    /// declares takes one or two words, so single-argument calls get a symbolic
    /// argument and two-argument calls are short; `execute` must handle both.
    uint256 internal constant CALLDATA_LEN = 36;

    function setUp() public {
        // Deployed owned by this test, then transferred: `ProtocolAdmin` takes
        // its targets as constructor arguments, so it cannot own them at
        // construction.
        pool = new MockAdminTarget(address(this));
        wrapper = new MockAdminTarget(address(this));
        admin = new ProtocolAdmin(address(pool), address(wrapper), GOV, GUARDIAN);
        pool.transferOwnership(address(admin));
        wrapper.transferOwnership(address(admin));
        // The pool is also a proxy, whose admin seat is handed over last.
        pool.changeProxyAdmin(address(admin));

        GUARDIAN_ROLE = admin.GUARDIAN_ROLE();
    }

    // --- `execute` cannot move ownership -----------------------------------

    /// No `execute` from governance moves the pool's owner, whatever the
    /// calldata.
    ///
    /// Stated over the full 2^32 selector space rather than the two guarded
    /// values. A guard comparing the wrong offset, masking the selector
    /// incorrectly, or missing either `Ownable` entry point fails here.
    ///
    /// Reverting calls are discarded, since a revert rolls back all state.
    /// `check_execute_forwardsOrdinaryCalls` shows this is not satisfied by an
    /// `execute` that refuses everything.
    function check_execute_neverMovesPoolOwnership() public {
        bytes memory data = svm.createBytes(CALLDATA_LEN, "data");

        vm.prank(GOV);
        (bool ok,) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(pool), data)));
        vm.assume(ok);

        assertEq(pool.owner(), address(admin), "execute moved pool ownership");
    }

    /// The same for the wrapper: if ownership of `SwapWrapper` left this
    /// contract, adapters could not be allowlisted or revoked through it.
    function check_execute_neverMovesWrapperOwnership() public {
        bytes memory data = svm.createBytes(CALLDATA_LEN, "data");

        vm.prank(GOV);
        (bool ok,) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(wrapper), data)));
        vm.assume(ok);

        assertEq(wrapper.owner(), address(admin), "execute moved wrapper ownership");
    }

    /// Both ownership selectors are refused with `OwnershipCallForbidden`,
    /// whatever argument follows them.
    ///
    /// Complements the two proofs above: this pins the revert reason for the two
    /// named selectors (so a rejection for an unrelated reason fails), while
    /// those quantify over all selectors to show nothing else moves ownership.
    function check_execute_refusesTransferOwnership() public {
        // The selector, then a symbolic destination word: the guard must not
        // depend on the destination, so a burn address is refused like any
        // other. `transferOwnership` itself rejects only `address(0)`.
        bytes memory tail = svm.createBytes(32, "tail");
        bytes memory data = bytes.concat(Ownable.transferOwnership.selector, tail);

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(pool), data)));

        _assertRejected(
            ok, ret, ProtocolAdmin.OwnershipCallForbidden.selector, "transferOwnership slipped through execute"
        );
    }

    /// `renounceOwnership` takes no arguments, so the quantifier is over trailing
    /// bytes: Solidity's dispatcher ignores appended data, and the guard must
    /// also refuse regardless of it.
    function check_execute_refusesRenounceOwnership() public {
        bytes memory tail = svm.createBytes(32, "tail");
        bytes memory data = bytes.concat(Ownable.renounceOwnership.selector, tail);

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(pool), data)));

        _assertRejected(
            ok, ret, ProtocolAdmin.OwnershipCallForbidden.selector, "renounceOwnership slipped through execute"
        );
    }

    /// No `execute` from governance moves the pool's proxy admin, whatever the
    /// calldata. That seat queues and cancels upgrades, so moving it alone would
    /// leave a pool owned here but upgradeable by someone else.
    ///
    /// Stated over every selector, like the ownership proofs above.
    /// `check_execute_forwardsOrdinaryCalls` shows the assumed success is
    /// reachable.
    function check_execute_neverMovesProxyAdmin() public {
        bytes memory data = svm.createBytes(CALLDATA_LEN, "data");

        vm.prank(GOV);
        (bool ok,) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(pool), data)));
        vm.assume(ok);

        assertEq(pool.proxyAdmin(), address(admin), "execute moved the proxy admin");
    }

    /// `changeProxyAdmin` is refused with `ProxyAdminCallForbidden` for every
    /// destination word, pinning the reason the proof above relies on.
    function check_execute_refusesChangeProxyAdmin() public {
        bytes memory tail = svm.createBytes(32, "tail");
        bytes memory data = bytes.concat(MockAdminTarget.changeProxyAdmin.selector, tail);

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(pool), data)));

        _assertRejected(
            ok, ret, ProtocolAdmin.ProxyAdminCallForbidden.selector, "changeProxyAdmin slipped through execute"
        );
    }

    /// Non-vacuity: an ordinary governance call goes through `execute`, so the
    /// proofs above are not satisfied by an `execute` that always reverts.
    function check_execute_forwardsOrdinaryCalls(uint256 v) public {
        vm.prank(GOV);
        admin.execute(address(pool), abi.encodeCall(MockAdminTarget.setParam, (v)));

        assertEq(pool.touched(), v, "execute did not forward an ordinary call");
    }

    /// Self-calls are refused for every calldata, keeping `execute` away from the
    /// inherited role-management surface. Reaching `grantRole` with
    /// `msg.sender == address(this)` would let one proposal grant a guardian role
    /// or revoke governance's admin role.
    function check_execute_refusesEverySelfCall() public {
        bytes memory data = svm.createBytes(CALLDATA_LEN, "data");

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(admin), data)));

        _assertRejected(ok, ret, ProtocolAdmin.SelfCallForbidden.selector, "execute reached its own role surface");
    }

    /// `execute` rejects every caller without `DEFAULT_ADMIN_ROLE`, for every
    /// target and every calldata, including the guardian, which holds a
    /// different role on this contract.
    function check_execute_rejectsEveryNonAdmin(address caller, address target) public {
        vm.assume(caller != GOV);
        bytes memory data = svm.createBytes(CALLDATA_LEN, "data");

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (target, data)));

        _assertRejected(ok, ret, IAccessControl.AccessControlUnauthorizedAccount.selector, "a non-admin executed");
    }

    // --- The guardian's switches are one-way --------------------------------

    /// `disableAsset` sets the flag to `true` for every id, and no argument lets
    /// a guardian set it back.
    ///
    /// The direction is fixed in bytecode, so the proof checks the recorded value
    /// is `true` for any id. Re-enabling requires a proposal through `execute`,
    /// for which the guardian lacks the role.
    function check_guardian_disableAssetIsOneWay(uint64 id) public {
        vm.prank(GUARDIAN);
        admin.disableAsset(id);

        assertTrue(pool.disabled(id), "disableAsset did not disable");
    }

    /// The same for the yield halt: a guardian can stop further supply to a vault
    /// but cannot resume it.
    function check_guardian_haltYieldIsOneWay(uint64 id) public {
        vm.prank(GUARDIAN);
        admin.haltYield(id);

        assertTrue(pool.halted(id), "haltYield did not halt");
    }

    /// The same for the adapter allowlist: an allowlisted adapter is called with
    /// escrowed funds, so a guardian may revoke an adapter but never add one.
    function check_guardian_disallowAdapterIsOneWay(address adapter) public {
        // Start with the adapter allowlisted.
        vm.prank(GOV);
        admin.execute(address(wrapper), abi.encodeCall(MockAdminTarget.setAdapterAllowed, (adapter, true)));
        assertTrue(wrapper.adapterAllowed(adapter));

        vm.prank(GUARDIAN);
        admin.disallowAdapter(adapter);

        assertFalse(wrapper.adapterAllowed(adapter), "disallowAdapter did not revoke");
    }

    /// Every guardian entry point rejects every caller without the role, for
    /// every argument, including governance, which holds `DEFAULT_ADMIN_ROLE`
    /// but not `GUARDIAN_ROLE`.
    ///
    /// Enumerated rather than using `svm.createCalldata`: `execute` forwards
    /// symbolic calldata to a symbolic target, so quantifying over the whole ABI
    /// would quantify over every call to every address (see `README.md`).
    function check_guardian_entryPointsRejectEveryNonGuardian(
        address caller,
        uint64 id,
        address adapter,
        uint256 duration
    ) public {
        vm.assume(!admin.hasRole(GUARDIAN_ROLE, caller));

        vm.prank(caller);
        (bool a, bytes memory ra) = address(admin).call(abi.encodeCall(ProtocolAdmin.disableAsset, (id)));
        vm.prank(caller);
        (bool b, bytes memory rb) = address(admin).call(abi.encodeCall(ProtocolAdmin.haltYield, (id)));
        vm.prank(caller);
        (bool c, bytes memory rc) = address(admin).call(abi.encodeCall(ProtocolAdmin.emergencyUnwind, (id)));
        vm.prank(caller);
        (bool d, bytes memory rd) = address(admin).call(abi.encodeCall(ProtocolAdmin.disallowAdapter, (adapter)));
        vm.prank(caller);
        (bool e, bytes memory re) = address(admin).call(abi.encodeCall(ProtocolAdmin.pauseSpends, (duration)));

        bytes4 denied = IAccessControl.AccessControlUnauthorizedAccount.selector;
        _assertRejected(a, ra, denied, "a non-guardian disabled an asset");
        _assertRejected(b, rb, denied, "a non-guardian halted yield");
        _assertRejected(c, rc, denied, "a non-guardian unwound a venue");
        _assertRejected(d, rd, denied, "a non-guardian revoked an adapter");
        _assertRejected(e, re, denied, "a non-guardian paused spends");
        assertEq(pool.pausedFor(), 0);
    }

    /// The guardian's pause reaches the pool's proxy for every duration.
    /// `ProtocolAdmin` forwards the duration unchanged, leaving the ceiling and
    /// the one-shot latch to the proxy, which proves them in
    /// `DelayedUpgradeProxy.symbolic.t.sol`.
    function check_guardian_pauseSpendsReachesTheProxy(uint256 duration) public {
        vm.prank(GUARDIAN);
        admin.pauseSpends(duration);

        assertEq(pool.pausedFor(), duration, "pause did not reach the proxy");
    }

    /// The guardian cannot reach the governance surface: neither `execute` nor
    /// `migrateAdmin`. This bounds a compromised guardian key to availability
    /// impact.
    function check_guardian_cannotReachGovernanceSurface(address newAdmin) public {
        bytes memory data = svm.createBytes(CALLDATA_LEN, "data");

        vm.prank(GUARDIAN);
        (bool exec,) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(pool), data)));
        vm.prank(GUARDIAN);
        (bool migrate,) = address(admin).call(abi.encodeCall(ProtocolAdmin.migrateAdmin, (newAdmin)));

        assertFalse(exec, "guardian executed");
        assertFalse(migrate, "guardian migrated the admin");
        assertEq(pool.owner(), address(admin));
        assertEq(wrapper.owner(), address(admin));
        assertEq(pool.proxyAdmin(), address(admin));
    }

    // --- `migrateAdmin` -----------------------------------------------------

    /// `migrateAdmin` moves both owners in one call.
    ///
    /// This prevents split ownership: since `ProtocolAdmin`'s targets are
    /// immutable, a pool under one admin and a wrapper under another could not
    /// be driven by either.
    function check_migrate_movesBothOwnersTogether() public {
        MockSuccessorAdmin next = new MockSuccessorAdmin(address(pool), address(wrapper));
        next.grant(DEFAULT_ADMIN_ROLE, GOV);

        vm.prank(GOV);
        admin.migrateAdmin(address(next));

        assertEq(pool.owner(), address(next), "pool did not move");
        assertEq(wrapper.owner(), address(next), "wrapper did not move");
    }

    /// The proxy admin moves in the same call as ownership, so upgrade authority
    /// cannot stay behind with a retired governance while the successor owns the
    /// pool.
    function check_migrate_movesProxyAdminWithOwnership() public {
        MockSuccessorAdmin next = new MockSuccessorAdmin(address(pool), address(wrapper));
        next.grant(DEFAULT_ADMIN_ROLE, GOV);

        vm.prank(GOV);
        admin.migrateAdmin(address(next));

        assertEq(pool.proxyAdmin(), address(next), "proxy admin stayed behind");
        assertEq(pool.owner(), address(next));
        assertEq(wrapper.owner(), address(next));
    }

    /// Migration is refused while the proxy admin sits anywhere but here, for
    /// every holder, and nothing moves. Otherwise ownership would leave and the
    /// upgrade seat would stay with whoever holds it.
    function check_migrate_rejectsWhenProxyAdminNotHeld(address holder) public {
        vm.assume(holder != address(admin) && holder != address(0));
        // `execute` cannot move the seat; this contract hands it over directly.
        vm.prank(address(admin));
        pool.changeProxyAdmin(holder);

        MockSuccessorAdmin next = new MockSuccessorAdmin(address(pool), address(wrapper));
        next.grant(DEFAULT_ADMIN_ROLE, GOV);

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.migrateAdmin, (address(next))));

        _assertRejected(ok, ret, ProtocolAdmin.ProxyAdminNotHeld.selector, "migrated without the proxy admin");
        assertEq(pool.owner(), address(admin));
        assertEq(wrapper.owner(), address(admin));
        assertEq(pool.proxyAdmin(), holder);
    }

    /// A successor claiming a different pool or wrapper is refused, for every
    /// address it could claim, and neither owner moves.
    ///
    /// These checks reject a misconfigured successor, not a hostile one: a
    /// hostile successor controls its own getters, and the timelock delay bounds
    /// that case.
    function check_migrate_rejectsMismatchedTargets(address claimedPool, address claimedWrapper) public {
        vm.assume(claimedPool != address(pool) || claimedWrapper != address(wrapper));

        MockSuccessorAdmin next = new MockSuccessorAdmin(claimedPool, claimedWrapper);
        next.grant(DEFAULT_ADMIN_ROLE, GOV);

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.migrateAdmin, (address(next))));

        assertFalse(ok, "migrated to a successor wired elsewhere");
        bytes4 sel = bytes4(ret);
        assertTrue(
            sel == ProtocolAdmin.PoolMismatch.selector || sel == ProtocolAdmin.WrapperMismatch.selector,
            "rejected for the wrong reason"
        );
        assertEq(pool.owner(), address(admin));
        assertEq(wrapper.owner(), address(admin));
    }

    /// A successor this Timelock does not administer is refused; migrating to one
    /// would leave the pool under a contract governance cannot drive, equivalent
    /// to renouncing.
    function check_migrate_rejectsUngovernedSuccessor() public {
        MockSuccessorAdmin next = new MockSuccessorAdmin(address(pool), address(wrapper));
        // DEFAULT_ADMIN_ROLE is not granted to GOV.

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.migrateAdmin, (address(next))));

        _assertRejected(
            ok, ret, ProtocolAdmin.AdminNotGoverned.selector, "migrated to a successor this timelock cannot drive"
        );
        assertEq(pool.owner(), address(admin));
    }

    /// Ownership cannot move to any account without code. An EOA successor has
    /// no `POOL()` to check and no role table, so the pool would be unmanageable.
    function check_migrate_rejectsEveryCodelessSuccessor(address newAdmin) public {
        vm.assume(newAdmin.code.length == 0);

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.migrateAdmin, (newAdmin)));

        _assertRejected(ok, ret, ProtocolAdmin.NotAContract.selector, "migrated ownership to a codeless account");
        assertEq(pool.owner(), address(admin));
        assertEq(wrapper.owner(), address(admin));
    }

    /// `migrateAdmin` rejects every caller without `DEFAULT_ADMIN_ROLE`, for
    /// every candidate successor.
    function check_migrate_rejectsEveryNonAdmin(address caller, address newAdmin) public {
        vm.assume(caller != GOV);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.migrateAdmin, (newAdmin)));

        _assertRejected(
            ok, ret, IAccessControl.AccessControlUnauthorizedAccount.selector, "a non-admin migrated the admin"
        );
        assertEq(pool.owner(), address(admin));
    }
}
