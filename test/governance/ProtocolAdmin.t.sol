// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { MASP } from "../../src/MASP.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { ERC4626Venue } from "../../src/yield/ERC4626Venue.sol";
import { ProtocolAdmin } from "../../src/governance/ProtocolAdmin.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// The guardian's authority, and its limits. The design claim being tested is
/// that the guardian can only ever *reduce* what the protocol does — every
/// function below hardcodes its direction, and nothing here can re-enable,
/// re-rate, or repoint anything.
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

    // ============== Guardian can turn things off =============================

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

    // ============== ...and nothing else ======================================

    /// There is no re-enable path on the guardian surface at all. Undoing any of
    /// the four costs a full proposal — that asymmetry is the whole safety
    /// argument for granting the role.
    function test_guardianCannotReEnableAnything() public {
        vm.prank(guardian);
        protocolAdmin.disableAsset(ASSET_ID);

        vm.prank(guardian);
        vm.expectRevert();
        protocolAdmin.execute(address(masp), abi.encodeCall(AssetRegistry.setAssetDisabled, (ASSET_ID, false)));

        assertTrue(masp.asset(ASSET_ID).disabled, "guardian re-enabled an asset");
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

    /// Re-enabling is possible, but only the long way round.
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

    /// The guardian is not entrenched: the Timelock administers the role and can
    /// rotate it by proposal.
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

    /// Self-calls would let `execute` reach the role surface with
    /// `msg.sender == address(this)`.
    function test_executeRejectsSelfCall() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(protocolAdmin),
            abi.encodeCall(ProtocolAdmin.execute, (address(protocolAdmin), abi.encodeCall(MASP.setCancelDelay, (1))))
        );
        string memory d = "self call";
        _proposeAndSucceed(t, v, c, d);
        governor.queue(t, v, c, keccak256(bytes(d)));
        vm.warp(governor.proposalEta(governor.hashProposal(t, v, c, keccak256(bytes(d)))) + 1);
        vm.expectRevert();
        governor.execute(t, v, c, keccak256(bytes(d)));
    }

    /// A failing target must surface its own error, or a rejected proposal is
    /// undiagnosable.
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
