// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";

import { Bundler } from "../../src/bundler/Bundler.sol";
import { BundlerFactory } from "../../src/bundler/BundlerFactory.sol";

/// `BundlerFactory` deploy, the deployer's own `Bundler`, and their KEY=value
/// log, for the swap scripts.
///
/// The factory fixes the contracts every Bundler may call, so it is deployed
/// after all of them exist: MASP → NativeAdapter → SwapWrapper →
/// GenericCallWrapper → BundlerFactory → Bundler. The swap scripts deploy both
/// wrappers, so they deploy
/// the factory too.
abstract contract BaseBundlerDeploy is Script {
    /// `nativeAdapter`, `swapWrapper` and `genericCallWrapper` may be zero on a
    /// chain without them.
    function _deployBundlerFactory(address masp, address nativeAdapter, address swapWrapper, address genericCallWrapper)
        internal
        returns (BundlerFactory)
    {
        return new BundlerFactory(masp, nativeAdapter, swapWrapper, genericCallWrapper);
    }

    /// Creates the broadcaster's `Bundler`, operated by `operator`, and hands
    /// it to `owner`.
    ///
    /// The factory makes the creator the owner, so a different owner requires a
    /// `transferOwnership` afterwards. The address remains the broadcaster's
    /// `predict`, since the creator salts it; after the transfer the
    /// broadcaster has no control over the Bundler.
    function _createBundler(BundlerFactory factory, address operator, address owner)
        internal
        returns (Bundler bundler)
    {
        address[] memory operators = new address[](1);
        operators[0] = operator;
        bundler = factory.create(operators);
        if (bundler.owner() != owner) bundler.transferOwnership(owner);
        require(bundler.owner() == owner, "bundler owner");
    }

    /// `_createBundler` for the operator named by env `BUNDLER_OPERATOR` and
    /// the owner named by env `BUNDLER_OWNER`, for a deployment that also runs
    /// the first relayer. An unset operator skips it and returns address(0). An
    /// unset owner reverts when `ownerRequired`, and otherwise leaves the
    /// broadcaster as owner. Any other relayer calls `BundlerFactory.create`
    /// itself, from the key that will own its Bundler.
    function _createBundlerFromEnv(BundlerFactory factory, bool ownerRequired) internal returns (Bundler) {
        address operator = vm.envOr("BUNDLER_OPERATOR", address(0));
        if (operator == address(0)) return Bundler(address(0));
        address owner = vm.envOr("BUNDLER_OWNER", address(0));
        if (owner == address(0)) {
            require(!ownerRequired, "BUNDLER_OWNER unset");
            owner = tx.origin;
        }
        return _createBundler(factory, operator, owner);
    }

    /// KEY=value lines scraped by `e2e/src/stack.ts` and
    /// `backend/stack/scripts/deploy-contracts.sh`. `BUNDLER`, its owner and
    /// its operator are logged only when one was created.
    function _logBundlerKv(BundlerFactory factory, Bundler bundler) internal view {
        console2.log(string.concat("BUNDLER_FACTORY=", vm.toString(address(factory))));
        if (address(bundler) != address(0)) {
            console2.log(string.concat("BUNDLER=", vm.toString(address(bundler))));
            console2.log(string.concat("BUNDLER_OWNER=", vm.toString(bundler.owner())));
            console2.log(string.concat("BUNDLER_OPERATOR=", vm.toString(vm.envAddress("BUNDLER_OPERATOR"))));
        }
    }
}
