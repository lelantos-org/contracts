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
/// `ProtocolAdmin` exists to hold two guarantees that nothing else in the system
/// holds:
///
/// 1. **Ownership cannot leave except through `migrateAdmin`.** Every pool admin
///    function is `onlyOwner`, so an ownership move out of this contract bricks
///    the whole admin surface — no asset registration, no rate change, no
///    guardian response, permanently. `execute` is an arbitrary-call primitive
///    guarded by nothing but a four-byte comparison, which makes that
///    comparison the single point the guarantee rests on.
/// 2. **The guardian's switches are one-way.** The guardian may close things
///    inside the timelock delay but may never open them, so a compromised
///    guardian key costs availability and never custody.
///
/// Both are statements about *every* calldata and *every* caller, which is what
/// makes them worth a solver rather than a fuzzer: the selector guard is a
/// two-value comparison against a 2^32 space, and a fuzzer that samples
/// `bytes calldata` essentially never draws either value. Here the tail beyond
/// the selector is symbolic too, so a guard that matched on more than the
/// leading four bytes would be caught.
///
/// Everything reachable is comparisons and mapping writes — no arithmetic, no
/// hashing beyond role ids fixed at compile time — so the whole file solves in
/// well under a second.
///
/// The pool and wrapper are `MockAdminTarget`, for the reason given on that
/// contract: `svm.createCalldata` against a real `MASP` is the non-terminating
/// shape `README.md` warns about, and none of these properties are about what
/// the pool does with the forwarded call.
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
    /// four-byte selector plus one full word of arguments. Every selector
    /// `MockAdminTarget` declares takes one or two words, so this reaches the
    /// single-argument ones with a symbolic argument and leaves the two-argument
    /// ones short — both of which are call shapes `execute` must handle.
    uint256 internal constant CALLDATA_LEN = 36;

    function setUp() public {
        // Deployed owned by this test, then handed over: `ProtocolAdmin` takes
        // its targets as constructor arguments, so it cannot be their owner at
        // the moment they are constructed.
        pool = new MockAdminTarget(address(this));
        wrapper = new MockAdminTarget(address(this));
        admin = new ProtocolAdmin(address(pool), address(wrapper), GOV, GUARDIAN);
        pool.transferOwnership(address(admin));
        wrapper.transferOwnership(address(admin));

        GUARDIAN_ROLE = admin.GUARDIAN_ROLE();
    }

    // --- `execute` cannot move ownership -----------------------------------

    /// No `execute` from governance moves the pool's owner, whatever the
    /// calldata.
    ///
    /// This is the guarantee the contract exists for, stated over the whole
    /// 2^32 selector space rather than the two values the guard names. A guard
    /// that compared the wrong offset, masked the selector incorrectly, or
    /// missed one of the two `Ownable` entry points fails here.
    ///
    /// Reverting calls are dropped rather than asserted on: a revert rolls back
    /// all state, so it cannot move an owner. `check_execute_forwardsOrdinaryCalls`
    /// is the non-vacuity anchor — without it this would also be satisfied by an
    /// `execute` that refused everything.
    function check_execute_neverMovesPoolOwnership() public {
        bytes memory data = svm.createBytes(CALLDATA_LEN, "data");

        vm.prank(GOV);
        (bool ok,) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(pool), data)));
        vm.assume(ok);

        assertEq(pool.owner(), address(admin), "execute moved pool ownership");
    }

    /// The same over the wrapper, which shares the guard and the failure mode:
    /// an unowned `SwapWrapper` can never have an adapter allowlisted or
    /// revoked again.
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
    /// Stronger than the two proofs above in one direction — it pins the revert
    /// reason, so a guard that started rejecting these for an unrelated reason
    /// (a bad target, an exhausted role) would fail rather than pass — and
    /// weaker in another, since it names the two selectors instead of
    /// quantifying over them. Both directions are worth having: this one says
    /// the guard fires, those say nothing else slips past it.
    function check_execute_refusesTransferOwnership() public {
        // The selector, then a symbolic destination word: the guard must not
        // depend on where ownership was being sent, so a burn address is
        // refused like any other. `transferOwnership` itself rejects only
        // `address(0)`, which is why that is not sufficient on its own.
        bytes memory tail = svm.createBytes(32, "tail");
        bytes memory data = bytes.concat(Ownable.transferOwnership.selector, tail);

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(pool), data)));

        _assertRejected(
            ok, ret, ProtocolAdmin.OwnershipCallForbidden.selector, "transferOwnership slipped through execute"
        );
    }

    /// `renounceOwnership` takes no arguments, so the interesting quantifier is
    /// over the trailing bytes: a caller may append anything, and Solidity's
    /// dispatcher ignores it. The guard must too.
    function check_execute_refusesRenounceOwnership() public {
        bytes memory tail = svm.createBytes(32, "tail");
        bytes memory data = bytes.concat(Ownable.renounceOwnership.selector, tail);

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(pool), data)));

        _assertRejected(
            ok, ret, ProtocolAdmin.OwnershipCallForbidden.selector, "renounceOwnership slipped through execute"
        );
    }

    /// Non-vacuity: the ordinary governance call `execute` exists to carry does
    /// go through. Without this the proofs above hold of a contract whose
    /// `execute` reverts unconditionally.
    function check_execute_forwardsOrdinaryCalls(uint256 v) public {
        vm.prank(GOV);
        admin.execute(address(pool), abi.encodeCall(MockAdminTarget.setParam, (v)));

        assertEq(pool.touched(), v, "execute did not forward an ordinary call");
    }

    /// Self-calls are refused for every calldata, which is what keeps `execute`
    /// away from the inherited role-management surface. Reaching `grantRole`
    /// with `msg.sender == address(this)` would let one proposal mint itself a
    /// guardian, or revoke governance's own admin role.
    function check_execute_refusesEverySelfCall() public {
        bytes memory data = svm.createBytes(CALLDATA_LEN, "data");

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (address(admin), data)));

        _assertRejected(ok, ret, ProtocolAdmin.SelfCallForbidden.selector, "execute reached its own role surface");
    }

    /// `execute` rejects every caller without `DEFAULT_ADMIN_ROLE`, for every
    /// target and every calldata — the guardian included. The guardian holds a
    /// role on this contract, so "not governance" is the property, not "no
    /// role at all".
    function check_execute_rejectsEveryNonAdmin(address caller, address target) public {
        vm.assume(caller != GOV);
        bytes memory data = svm.createBytes(CALLDATA_LEN, "data");

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.execute, (target, data)));

        _assertRejected(ok, ret, IAccessControl.AccessControlUnauthorizedAccount.selector, "a non-admin executed");
    }

    // --- The guardian's switches are one-way --------------------------------

    /// `disableAsset` drives the flag to `true` for every id, and there is no
    /// argument by which a guardian could drive it back.
    ///
    /// The direction is fixed in bytecode — the point of splitting these out of
    /// `execute` — so the proof is that the recorded value is `true` whatever
    /// id is named. Re-enabling requires a proposal through `execute`, which
    /// the caller here does not hold the role for.
    function check_guardian_disableAssetIsOneWay(uint64 id) public {
        vm.prank(GUARDIAN);
        admin.disableAsset(id);

        assertTrue(pool.disabled(id), "disableAsset did not disable");
    }

    /// The same for the yield halt: a guardian stops further supply to a vault
    /// and cannot resume it.
    function check_guardian_haltYieldIsOneWay(uint64 id) public {
        vm.prank(GUARDIAN);
        admin.haltYield(id);

        assertTrue(pool.halted(id), "haltYield did not halt");
    }

    /// And for the adapter allowlist, where the direction matters most: an
    /// allowlisted adapter is called with escrowed funds, so a guardian must be
    /// able to revoke one and must never be able to add one.
    function check_guardian_disallowAdapterIsOneWay(address adapter) public {
        // Start from the state a revocation is interesting in.
        vm.prank(GOV);
        admin.execute(address(wrapper), abi.encodeCall(MockAdminTarget.setAdapterAllowed, (adapter, true)));
        assertTrue(wrapper.adapterAllowed(adapter));

        vm.prank(GUARDIAN);
        admin.disallowAdapter(adapter);

        assertFalse(wrapper.adapterAllowed(adapter), "disallowAdapter did not revoke");
    }

    /// Every guardian entry point rejects every caller without the role, for
    /// every argument — governance included, since it holds
    /// `DEFAULT_ADMIN_ROLE` and not `GUARDIAN_ROLE`.
    ///
    /// Enumerated rather than taken from `svm.createCalldata`: this contract's
    /// `execute` forwards symbolic calldata to a symbolic target, so
    /// quantifying over its whole ABI would quantify over every call to every
    /// address. `README.md` records that trap.
    function check_guardian_entryPointsRejectEveryNonGuardian(address caller, uint64 id, address adapter) public {
        vm.assume(!admin.hasRole(GUARDIAN_ROLE, caller));

        vm.prank(caller);
        (bool a, bytes memory ra) = address(admin).call(abi.encodeCall(ProtocolAdmin.disableAsset, (id)));
        vm.prank(caller);
        (bool b, bytes memory rb) = address(admin).call(abi.encodeCall(ProtocolAdmin.haltYield, (id)));
        vm.prank(caller);
        (bool c, bytes memory rc) = address(admin).call(abi.encodeCall(ProtocolAdmin.emergencyUnwind, (id)));
        vm.prank(caller);
        (bool d, bytes memory rd) = address(admin).call(abi.encodeCall(ProtocolAdmin.disallowAdapter, (adapter)));

        bytes4 denied = IAccessControl.AccessControlUnauthorizedAccount.selector;
        _assertRejected(a, ra, denied, "a non-guardian disabled an asset");
        _assertRejected(b, rb, denied, "a non-guardian halted yield");
        _assertRejected(c, rc, denied, "a non-guardian unwound a venue");
        _assertRejected(d, rd, denied, "a non-guardian revoked an adapter");
    }

    /// The guardian cannot reach governance's surface: neither the arbitrary
    /// call nor the ownership exit. This is the role split stated from the
    /// other side, and it is what bounds a compromised guardian key to
    /// availability damage.
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
    }

    // --- `migrateAdmin` -----------------------------------------------------

    /// The sanctioned exit moves both owners, in one call.
    ///
    /// Split ownership is the failure this shape prevents: a pool under one
    /// admin and a wrapper under another cannot be driven by either, since
    /// `ProtocolAdmin`'s targets are immutable.
    function check_migrate_movesBothOwnersTogether() public {
        MockSuccessorAdmin next = new MockSuccessorAdmin(address(pool), address(wrapper));
        next.grant(DEFAULT_ADMIN_ROLE, GOV);

        vm.prank(GOV);
        admin.migrateAdmin(address(next));

        assertEq(pool.owner(), address(next), "pool did not move");
        assertEq(wrapper.owner(), address(next), "wrapper did not move");
    }

    /// A successor claiming a different pool or wrapper is refused, for every
    /// address it could claim, and neither owner moves.
    ///
    /// These checks stop a mis-wired successor, not a hostile one — a hostile
    /// successor controls its own getters, and the timelock delay bounds that
    /// case. What the proof establishes is that the accident is impossible.
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

    /// A successor this Timelock does not administer is refused. Migrating to
    /// one would strand the pool under a contract governance cannot drive,
    /// which is indistinguishable from renouncing.
    function check_migrate_rejectsUngovernedSuccessor() public {
        MockSuccessorAdmin next = new MockSuccessorAdmin(address(pool), address(wrapper));
        // Deliberately not granted to GOV.

        vm.prank(GOV);
        (bool ok, bytes memory ret) = address(admin).call(abi.encodeCall(ProtocolAdmin.migrateAdmin, (address(next))));

        _assertRejected(
            ok, ret, ProtocolAdmin.AdminNotGoverned.selector, "migrated to a successor this timelock cannot drive"
        );
        assertEq(pool.owner(), address(admin));
    }

    /// Ownership cannot land on an account with no code, for any such address.
    /// An EOA successor has no `POOL()` to check and no role table to grant
    /// through — the pool would simply be gone.
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
