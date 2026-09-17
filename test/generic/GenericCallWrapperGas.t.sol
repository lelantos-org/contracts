// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Test.sol";

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";

import { GenericCallTestBase } from "./GenericCallTestBase.sol";
import { GenericIntent } from "./GenericIntent.sol";
import { MockRouter } from "./mocks/MockCallTargets.sol";

/// Gas of `execute` for the common shapes, against the stub pool: the figures
/// include the mock router and pool, so they are for comparing wrapper changes,
/// not for quoting. Run under `--isolate` so every execution starts cold:
///
///     forge test --match-contract GenericCallWrapperGasTest --isolate -vv
contract GenericCallWrapperGasTest is GenericCallTestBase {
    function test_gas_swapOneOutput() public {
        _fundWithdraw();
        _report("swap, 1 output", _swapArgs(990, _pull(990) + SCALE));
    }

    function test_gas_splitTwoOutputs() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _splitCalls(_received(), _pull(400), _pull(500) + 1);
        a.outputs = _twoOutputs(_output(ASSET_B, 400), _output(ASSET_C, 500));
        _report("split, 2 outputs", a);
    }

    function test_gas_refund() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _oneCall(_call(address(router), abi.encodeCall(MockRouter.fail, ())));
        a.outputs = _oneOutput(_output(ASSET_B, 1));
        _report("refund", a);
    }

    function _report(string memory label, GenericCallWrapper.GenericArgs memory a) internal {
        GenericCallWrapper.GenericArgs memory signed = GenericIntent.bind(a);
        wrapper.execute(signed);
        Vm.Gas memory g = vm.lastCallGas();
        emit log_named_uint(string.concat(label, " gas"), g.gasTotalUsed);
    }
}
