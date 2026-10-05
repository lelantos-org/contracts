// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { CallExecutor } from "../../src/generic/CallExecutor.sol";
import { LelantosNameRegistrar } from "../../src/names/LelantosNameRegistrar.sol";

import { GenericCallTestBase } from "../generic/GenericCallTestBase.sol";
import { NameFixtures } from "./NameFixtures.sol";

/// A registrar charging its fee in token A, and the `GenericCallWrapper`
/// payload a wallet builds to register a handle: unshield A, approve and
/// register from the clone, re-shield what is left of A.
abstract contract NameRegistrationTestBase is GenericCallTestBase, NameFixtures {
    uint96 internal constant FEE = 100e10;

    LelantosNameRegistrar internal registrar;
    address internal controller;

    function setUp() public virtual override {
        super.setUp();
        controller = vm.addr(CONTROLLER_KEY);
        registrar =
            new LelantosNameRegistrar(OWNER, IERC20(address(tokenA)), FEE, TREASURY, new string[](0), address(0));
    }

    /// A registration made outside the wrapper, paying the fee from this contract.
    function _registerDirect(string memory label, string memory value, address ctl) internal {
        tokenA.mint(address(this), FEE);
        tokenA.approve(address(registrar), FEE);
        registrar.register(label, value, ctl);
    }

    /// The largest change note whose pull fits what the clone returns after
    /// paying the fee.
    function _changeUnits() internal pure returns (uint64 units) {
        uint256 returned = _received() - FEE;
        units = uint64(returned / SCALE);
        while (_pull(units) > returned) --units;
    }

    function _registerCalls(string memory label, uint256 approval) internal view returns (CallExecutor.Call[] memory) {
        return _twoCalls(
            _call(address(tokenA), abi.encodeCall(IERC20.approve, (address(registrar), approval))),
            _call(address(registrar), abi.encodeCall(LelantosNameRegistrar.register, (label, VALUE, controller)))
        );
    }

    /// Registers `label`, with the change re-shielded as one note of A.
    function _registerArgs(string memory label) internal view returns (GenericCallWrapper.GenericArgs memory a) {
        a = _base();
        a.calls = _registerCalls(label, FEE);
        uint64 change = _changeUnits();
        a.outputs = _oneOutput(_output(ASSET_A, change));
        // The floor the wallet sets: the pull of the change note.
        a.outputs[0].minOut = _pull(change);
    }
}
