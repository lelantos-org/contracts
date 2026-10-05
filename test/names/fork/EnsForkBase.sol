// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Ens } from "../../../script/base/Ens.sol";
import { LelantosNameRegistrar } from "../../../src/names/LelantosNameRegistrar.sol";

import { NameFixtures } from "../NameFixtures.sol";

interface IUniversalResolver {
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory, address);
}

/// A mainnet fork with a registrar holding one handle, and the encoders for
/// names under a test parent, for suites that resolve through ENS itself.
///
/// Skipped unless `FORK_TESTS=1`, so the default `forge test` stays offline:
///
///   FORK_TESTS=1 MAINNET_RPC_URL=... forge test --match-path 'test/names/fork/*'
abstract contract EnsForkBase is Test, NameFixtures {
    /// What viem and the ENS app resolve through.
    IUniversalResolver internal constant UNIVERSAL_RESOLVER =
        IUniversalResolver(0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe);

    /// A second-level label unlikely to exist under any TLD.
    string internal constant PARENT_LABEL = "lelantos-fork-test-parent";

    LelantosNameRegistrar internal registrar;

    /// Selects the fork and deploys the registrar with `LABEL` registered, or
    /// skips the test. Returns whether the suite should go on setting up.
    function _forkWithRegistrar() internal returns (bool) {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        registrar = new LelantosNameRegistrar(OWNER, IERC20(address(0)), 0, address(0), new string[](0), address(0));
        registrar.register(LABEL, VALUE, vm.addr(CONTROLLER_KEY));
        return true;
    }

    function _tldNode(string memory tld) internal pure returns (bytes32) {
        return Ens.subnode(bytes32(0), tld);
    }

    /// The node of the test parent under `tld`.
    function _parentNode(string memory tld) internal pure returns (bytes32) {
        return Ens.subnode(_tldNode(tld), PARENT_LABEL);
    }

    /// The test parent under `tld`, in DNS wire format.
    function _parentName(string memory tld) internal pure returns (bytes memory) {
        return Ens.dnsEncode(string.concat(PARENT_LABEL, ".", tld));
    }

    /// `text(key)` of `<label>.<parent>.<tld>` through the Universal Resolver.
    function _resolveText(string memory label, string memory tld, string memory key)
        internal
        view
        returns (string memory value, address resolver)
    {
        bytes memory out;
        (out, resolver) = UNIVERSAL_RESOLVER.resolve(
            _subname(label, _parentName(tld)), _textCall(Ens.subnode(_parentNode(tld), label), key)
        );
        value = abi.decode(out, (string));
    }
}
