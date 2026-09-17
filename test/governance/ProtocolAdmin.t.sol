// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { MASP } from "../../src/MASP.sol";
import { IUpgradeProxyAdmin } from "../../src/interfaces/IProtocolAdmin.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { ERC4626Venue } from "../../src/yield/ERC4626Venue.sol";
import { ProtocolAdmin } from "../../src/governance/ProtocolAdmin.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// Guardian authority and its limits. The guardian can only reduce protocol
/// functionality: each guardian function hardcodes its direction, and none can
/// re-enable, re-rate, or repoint anything.
contract ProtocolAdminTest is GovTestBase {
    uint64 internal constant YIELD_ID = 2;

    ERC4626Venue internal venue;
    MockERC4626 internal vault;

    function _registerYieldAsset() internal {
        vault = new MockERC4626(IERC20(address(token)));
        venue = new ERC4626Venue(address(masp), address(vault), address(token));
        _passAdminCall(
            address(masp),
            abi.encodeCall(
                MASP.addYieldAsset, (YIELD_ID, IERC20(address(token)), SCALE, 25, 25, address(venue), 500, 1000)
            ),
            "register yield asset"
        );
    }

    // ============== Guardian disable switches ================================

    function test_guardianDisablesAsset() public {
        vm.prank(guardian);
        protocolAdmin.disableAsset(ASSET_ID);
        assertTrue(masp.asset(ASSET_ID).disabled, "asset not disabled");
    }

    function test_guardianDisallowsAdapter() public {
        address adapter = makeAddr("adapter");
        _passAdminCall(
            address(wrapper), abi.encodeCall(SwapWrapper.setAdapterAllowed, (adapter, true)), "allow adapter"
        );
        assertTrue(wrapper.adapterAllowed(adapter));

        vm.prank(guardian);
        protocolAdmin.disallowAdapter(adapter);
        assertFalse(wrapper.adapterAllowed(adapter), "adapter not revoked");
    }

    function test_guardianHaltsYield() public {
        _registerYieldAsset();
        assertFalse(masp.yieldState(YIELD_ID).halted);

        vm.prank(guardian);
        protocolAdmin.haltYield(YIELD_ID);
        assertTrue(masp.yieldState(YIELD_ID).halted, "yield not halted");
    }

    function test_guardianEmergencyUnwinds() public {
        _registerYieldAsset();
        vm.prank(guardian);
        protocolAdmin.emergencyUnwind(YIELD_ID);
        // Unwinding also halts, leaving the asset as zero-yield custody.
        assertTrue(masp.yieldState(YIELD_ID).halted, "unwind did not halt");
    }

    /// The guardian halts spends through the proxy, as its admin, and the pause
    /// is reported like the other switches.
    function test_guardianPausesSpends() public {
        vm.expectEmit(address(protocolAdmin));
        emit ProtocolAdmin.GuardianAction(IUpgradeProxyAdmin.pauseSpends.selector, 0, address(masp));
        vm.prank(guardian);
        protocolAdmin.pauseSpends(1 days);

        // `setUp` leaves the clock at T0 + 1.
        assertEq(_poolProxy().spendsPausedUntil(), T0 + 1 + 1 days, "spends not paused");
        assertTrue(_poolProxy().guardianPauseUsed(), "latch not set");
    }

    /// The proxy's latch holds through `ProtocolAdmin`: the guardian cannot chain
    /// pauses into an indefinite freeze.
    function test_revert_GuardianPauseAlreadyUsed_secondGuardianPause() public {
        vm.prank(guardian);
        protocolAdmin.pauseSpends(1 days);

        vm.prank(guardian);
        vm.expectRevert(DelayedUpgradeProxy.GuardianPauseAlreadyUsed.selector);
        protocolAdmin.pauseSpends(1 days);
    }

    /// Only governance re-arms the guardian's pause, by a proposal carrying
    /// `resetGuardianPause` through `execute`.
    function test_governanceReArmsGuardianPauseViaExecute() public {
        vm.prank(guardian);
        protocolAdmin.pauseSpends(1 days);

        _passAdminCall(address(masp), abi.encodeCall(DelayedUpgradeProxy.resetGuardianPause, ()), "re-arm pause");
        assertFalse(_poolProxy().guardianPauseUsed(), "governance could not re-arm the pause");

        vm.prank(guardian);
        protocolAdmin.pauseSpends(1 days);
        assertTrue(_poolProxy().guardianPauseUsed());
    }

    function test_randomCallerCannotPauseSpends() public {
        address attacker = makeAddr("attacker");
        bytes32 guardianRole = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, guardianRole)
        );
        protocolAdmin.pauseSpends(1 days);
        assertFalse(_poolProxy().guardianPauseUsed());
    }

    // ============== Guardian limits ==========================================

    /// The guardian surface has no re-enable path. Undoing any of the switches,
    /// or re-arming the one-shot pause, requires a full proposal; this asymmetry
    /// is what makes granting the role safe.
    function test_guardianCannotReEnableAnything() public {
        vm.prank(guardian);
        protocolAdmin.disableAsset(ASSET_ID);
        vm.prank(guardian);
        protocolAdmin.pauseSpends(1 days);

        vm.prank(guardian);
        vm.expectRevert();
        protocolAdmin.execute(address(masp), abi.encodeCall(AssetRegistry.setAssetDisabled, (ASSET_ID, false)));

        vm.prank(guardian);
        vm.expectRevert();
        protocolAdmin.execute(address(masp), abi.encodeCall(DelayedUpgradeProxy.resetGuardianPause, ()));

        assertTrue(masp.asset(ASSET_ID).disabled, "guardian re-enabled an asset");
        assertTrue(_poolProxy().guardianPauseUsed(), "guardian re-armed its own pause");
    }

    function test_guardianCannotExecute() public {
        // Read the role first: an external call between `vm.prank` and the call
        // under test consumes the prank.
        bytes32 adminRole = protocolAdmin.DEFAULT_ADMIN_ROLE();
        bytes memory call = abi.encodeCall(AssetRegistry.setAssetFee, (ASSET_ID, 100, 100));

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, adminRole)
        );
        protocolAdmin.execute(address(masp), call);
    }

    function test_randomCallerCannotUseGuardianSwitches() public {
        address attacker = makeAddr("attacker");
        bytes32 guardianRole = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, guardianRole)
        );
        protocolAdmin.disableAsset(ASSET_ID);
    }

    /// Re-enabling is possible only through a governance proposal.
    function test_governanceCanReEnableWhatTheGuardianDisabled() public {
        vm.prank(guardian);
        protocolAdmin.disableAsset(ASSET_ID);
        assertTrue(masp.asset(ASSET_ID).disabled);

        _passAdminCall(
            address(masp), abi.encodeCall(AssetRegistry.setAssetDisabled, (ASSET_ID, false)), "re-enable asset"
        );
        assertFalse(masp.asset(ASSET_ID).disabled, "governance could not re-enable");
    }

    // ============== Role management ==========================================

    /// The Timelock administers the guardian role and can rotate it by proposal.
    function test_governanceCanRotateTheGuardian() public {
        address newGuardian = makeAddr("newGuardian");
        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(protocolAdmin), abi.encodeCall(IAccessControl.grantRole, (role, newGuardian)));
        _passProposal(t, v, c, "grant new guardian");

        (t, v, c) = _one(address(protocolAdmin), abi.encodeCall(IAccessControl.revokeRole, (role, guardian)));
        _passProposal(t, v, c, "revoke old guardian");

        assertTrue(protocolAdmin.hasRole(role, newGuardian));
        assertFalse(protocolAdmin.hasRole(role, guardian));

        vm.prank(newGuardian);
        protocolAdmin.disableAsset(ASSET_ID);

        vm.prank(guardian);
        vm.expectRevert();
        protocolAdmin.haltYield(YIELD_ID);
    }

    // ============== execute() guards =========================================

    /// Self-calls are rejected; they would let `execute` reach the role surface
    /// with `msg.sender == address(this)`.
    function test_executeRejectsSelfCall() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _adminCall(address(protocolAdmin), abi.encodeCall(MASP.setCancelDelay, (1)));
        string memory d = "self call";
        _queueToEta(t, v, c, d);
        vm.expectRevert();
        governor.execute(t, v, c, keccak256(bytes(d)));
    }

    /// `execute` cannot move the pool's proxy admin, whatever the target: that
    /// seat leaves only with ownership, through `migrateAdmin`.
    function test_executeRejectsChangeProxyAdmin() public {
        bytes memory call = abi.encodeCall(DelayedUpgradeProxy.changeProxyAdmin, (makeAddr("elsewhere")));

        vm.prank(address(timelock));
        vm.expectRevert(ProtocolAdmin.ProxyAdminCallForbidden.selector);
        protocolAdmin.execute(address(masp), call);

        // The guard reads the selector alone, so another target is refused too.
        vm.prank(address(timelock));
        vm.expectRevert(ProtocolAdmin.ProxyAdminCallForbidden.selector);
        protocolAdmin.execute(address(wrapper), call);

        assertEq(_poolProxy().proxyAdmin(), address(protocolAdmin), "execute moved the proxy admin");
    }

    /// A failing target's revert data is bubbled up, so a rejected proposal is
    /// diagnosable.
    function test_executeBubblesTargetRevert() public {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(999)));
        protocolAdmin.execute(address(masp), abi.encodeCall(AssetRegistry.setAssetFee, (999, 10, 10)));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ProtocolAdmin.ZeroAddress.selector);
        new ProtocolAdmin(address(0), address(wrapper), address(timelock), guardian);
        vm.expectRevert(ProtocolAdmin.ZeroAddress.selector);
        new ProtocolAdmin(address(masp), address(0), address(timelock), guardian);
        vm.expectRevert(ProtocolAdmin.ZeroAddress.selector);
        new ProtocolAdmin(address(masp), address(wrapper), address(0), guardian);
    }

    /// A zero guardian is legal: it deploys the no-guardian variant, and the role
    /// can be granted later by proposal.
    function test_zeroGuardianIsAllowed() public {
        ProtocolAdmin pa = new ProtocolAdmin(address(masp), address(wrapper), address(timelock), address(0));
        assertFalse(pa.hasRole(pa.GUARDIAN_ROLE(), address(0)));
        assertTrue(pa.hasRole(pa.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }
}
