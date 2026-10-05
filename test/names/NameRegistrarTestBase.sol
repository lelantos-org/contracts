// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LelantosNameRegistrar } from "../../src/names/LelantosNameRegistrar.sol";
import { LelantosNameResolver } from "../../src/names/LelantosNameResolver.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { NameFixtures } from "./NameFixtures.sol";

/// A registrar with no fee and two reserved labels, a resolver for
/// `lelantos.xyz` over it, and a token to charge a fee in.
abstract contract NameRegistrarTestBase is Test, NameFixtures {
    address internal constant RESERVED_CONTROLLER = address(0x5E5E);
    /// `lelantos.xyz` in DNS wire format.
    bytes internal constant PARENT = hex"086c656c616e746f730378797a00";

    LelantosNameRegistrar internal registrar;
    LelantosNameResolver internal resolver;
    MockERC20 internal feeToken;
    address internal controller;

    function setUp() public virtual {
        controller = vm.addr(CONTROLLER_KEY);
        feeToken = new MockERC20("Fee", "FEE", 6);
        string[] memory reserved = new string[](2);
        reserved[0] = "admin";
        reserved[1] = "support";
        registrar = _newRegistrar(reserved, RESERVED_CONTROLLER);
        resolver = new LelantosNameResolver(registrar, PARENT, TEXT_KEY, address(0));
    }

    /// A registrar owned by `OWNER`, charging nothing.
    function _newRegistrar(string[] memory reserved, address reservedController)
        internal
        returns (LelantosNameRegistrar)
    {
        return new LelantosNameRegistrar(OWNER, IERC20(address(0)), 0, address(0), reserved, reservedController);
    }

    /// `<label>.lelantos.xyz` in DNS wire format.
    function _name(string memory label) internal pure returns (bytes memory) {
        return _subname(label, PARENT);
    }

    /// `text(node, key)` calldata. The resolver ignores the node.
    function _textCall(string memory key) internal pure returns (bytes memory) {
        return _textCall(bytes32(0), key);
    }

    function _resolveText(string memory label) internal view returns (string memory) {
        return abi.decode(resolver.resolve(_name(label), _textCall(TEXT_KEY)), (string));
    }

    /// A `setValue` signature by `key` over the handle's current nonce.
    function _sign(uint256 key, string memory label, string memory value, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, registrar.setValueDigest(label, value, deadline));
        return abi.encodePacked(r, s, v);
    }

    function _setFee(uint96 amount) internal {
        vm.prank(OWNER);
        registrar.setFee(IERC20(address(feeToken)), amount, TREASURY);
    }
}
