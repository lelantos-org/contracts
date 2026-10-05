// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { HandoverName } from "../../../script/HandoverName.s.sol";
import { Ens } from "../../../script/base/Ens.sol";
import { LelantosNameResolver } from "../../../src/names/LelantosNameResolver.sol";

import { EnsForkBase } from "./EnsForkBase.sol";

interface IBaseRegistrarAdmin {
    function owner() external view returns (address);
    function addController(address controller) external;
    function register(uint256 id, address owner, uint256 duration) external returns (uint256);
}

/// Holds a `.eth` name and runs the handover as its holder.
contract HandoverNameHarness is HandoverName, IERC721Receiver {
    function handover(string memory label, address resolver, address timelock) external {
        _handover(label, resolver, timelock, address(this));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// `HandoverName` against mainnet's ENS: a freshly registered, unwrapped
/// `.eth` name ends with the wildcard resolver set and the Timelock as both
/// registrant and manager, and its handles resolve.
contract HandoverNameForkTest is EnsForkBase {
    HandoverNameHarness internal harness;
    LelantosNameResolver internal resolver;
    TimelockController internal timelock;
    bytes32 internal node;
    uint256 internal tokenId;

    function setUp() public {
        if (!_forkWithRegistrar()) return;

        timelock = new TimelockController(1 days, new address[](0), new address[](0), address(this));
        harness = new HandoverNameHarness();
        resolver = new LelantosNameResolver(registrar, _parentName("eth"), TEXT_KEY, address(0));
        tokenId = uint256(keccak256(bytes(PARENT_LABEL)));
        node = _parentNode("eth");
        _registerParentTo(address(harness));
    }

    /// Registers the test parent to `holder`, as a registrar controller would.
    function _registerParentTo(address holder) internal {
        IBaseRegistrarAdmin admin = IBaseRegistrarAdmin(address(Ens.ETH_REGISTRAR));
        vm.prank(admin.owner());
        admin.addController(address(this));
        admin.register(tokenId, holder, 365 days);
    }

    function test_handover_movesBothRolesAndSetsTheResolver() public {
        assertEq(Ens.ETH_REGISTRAR.ownerOf(tokenId), address(harness), "registrant before");
        assertEq(Ens.REGISTRY.owner(node), address(harness), "manager before");

        harness.handover(PARENT_LABEL, address(resolver), address(timelock));

        assertEq(Ens.REGISTRY.resolver(node), address(resolver), "resolver");
        assertEq(Ens.REGISTRY.owner(node), address(timelock), "manager");
        assertEq(Ens.ETH_REGISTRAR.ownerOf(tokenId), address(timelock), "registrant");

        (string memory value, address served) = _resolveText(LABEL, "eth", TEXT_KEY);
        assertEq(value, VALUE, "handle resolves");
        assertEq(served, address(resolver), "through the wildcard resolver");
    }

    /// After it the former holder controls nothing.
    function test_handover_leavesTheHolderWithoutControl() public {
        harness.handover(PARENT_LABEL, address(resolver), address(timelock));
        vm.prank(address(harness));
        vm.expectRevert();
        Ens.REGISTRY.setResolver(node, address(0));
        vm.prank(address(harness));
        vm.expectRevert();
        Ens.ETH_REGISTRAR.reclaim(tokenId, address(harness));
    }

    function test_handover_revert_resolverForAnotherParent() public {
        LelantosNameResolver other = new LelantosNameResolver(registrar, _parentName("xyz"), TEXT_KEY, address(0));
        vm.expectRevert(bytes("resolver serves another parent"));
        harness.handover(PARENT_LABEL, address(other), address(timelock));
    }

    function test_handover_revert_timelockWithoutCode() public {
        vm.expectRevert(bytes("timelock has no code"));
        harness.handover(PARENT_LABEL, address(resolver), address(0xDEAD));
    }

    function test_handover_revert_notTheRegistrant() public {
        HandoverNameHarness stranger = new HandoverNameHarness();
        vm.expectRevert(bytes("holder is not the registrant"));
        stranger.handover(PARENT_LABEL, address(resolver), address(timelock));
    }
}
