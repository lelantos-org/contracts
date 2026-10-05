// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";

import { LelantosNameResolver } from "../src/names/LelantosNameResolver.sol";

import { Ens } from "./base/Ens.sol";

/// Points an unwrapped `.eth` name at its `LelantosNameResolver` and moves the
/// name to the Timelock. Signed by the name's current holder, which must be
/// both its registrant and its manager.
///
/// Order: the resolver is set and the manager role moved while the holder
/// still holds the token, since `reclaim` needs it; the token goes last. After
/// it, every change to the name is a governance proposal. Every write is read
/// back and asserted.
///
/// A DNS-imported name is not handled here: its ENS owner is whatever its
/// `_ens` TXT record names, set by the claim transaction.
///
/// Required env:
///   NAME_LABEL    — the second-level label, e.g. `lelantosid` for `lelantosid.eth`
///   NAME_RESOLVER — the resolver deployed for that parent (must have code)
///   TIMELOCK      — the new holder (must have code)
contract HandoverName is Script {
    function run() external {
        require(block.chainid == 1, "ENS is on Ethereum mainnet");
        string memory label = vm.envString("NAME_LABEL");
        address resolver = vm.envAddress("NAME_RESOLVER");
        address timelock = vm.envAddress("TIMELOCK");

        vm.startBroadcast();
        _handover(label, resolver, timelock, tx.origin);
        vm.stopBroadcast();

        console2.log(string.concat("NAME=", label, ".eth"));
        console2.log(string.concat("NAME_HOLDER=", vm.toString(timelock)));
    }

    /// The three writes, made by `holder`, between their preconditions and
    /// the checks of what they left.
    function _handover(string memory label, address resolver, address timelock, address holder) internal {
        uint256 tokenId = uint256(keccak256(bytes(label)));
        bytes32 node = Ens.subnode(Ens.ETH_NODE, label);

        require(resolver.code.length != 0, "resolver has no code");
        require(timelock.code.length != 0, "timelock has no code");
        require(Ens.ETH_REGISTRAR.ownerOf(tokenId) == holder, "holder is not the registrant");
        require(Ens.REGISTRY.owner(node) == holder, "holder is not the manager (is the name wrapped?)");
        // The resolver must have been deployed for this very name.
        require(
            LelantosNameResolver(resolver).PARENT_NAME_HASH() == keccak256(Ens.dnsEncode(string.concat(label, ".eth"))),
            "resolver serves another parent"
        );

        Ens.REGISTRY.setResolver(node, resolver);
        Ens.ETH_REGISTRAR.reclaim(tokenId, timelock);
        Ens.ETH_REGISTRAR.safeTransferFrom(holder, timelock, tokenId);

        require(Ens.REGISTRY.resolver(node) == resolver, "resolver not set");
        require(Ens.REGISTRY.owner(node) == timelock, "manager not moved");
        require(Ens.ETH_REGISTRAR.ownerOf(tokenId) == timelock, "registrant not moved");
    }
}
