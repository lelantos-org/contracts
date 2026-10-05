// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LelantosNameRegistrar } from "../../../src/names/LelantosNameRegistrar.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { EnsForkBase } from "./EnsForkBase.sol";

/// Makes two calls in one transaction, as the wrapper's clone does, so the
/// allowance the first sets and the second spends is refunded as on chain.
contract TwoCalls {
    function run(address first, bytes calldata firstData, address second, bytes calldata secondData) external {
        (bool a,) = first.call(firstData);
        (bool b,) = second.call(secondData);
        require(a && b, "call failed");
    }
}

/// The fee leg of a registration with mainnet USDC against the plain ERC-20
/// `NameRegistrationGasTest` measures with: what USDC costs on top must stay
/// within `FEE_TOKEN_PREMIUM`, the allowance `REGISTER_MIN_GAS` is sized with.
///
/// Run under `--isolate`, so each measurement is a transaction of its own:
///
///   FORK_TESTS=1 MAINNET_RPC_URL=... forge test --match-path 'test/names/fork/*' --isolate
contract RegistrationGasForkTest is EnsForkBase {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint96 internal constant FEE = 5e6;

    function setUp() public {
        _forkWithRegistrar();
    }

    /// Gas of `[approve, register]` paying the fee in `token`.
    function _feeLegGas(address token) internal returns (uint256) {
        TwoCalls clone = new TwoCalls();
        LelantosNameRegistrar paid =
            new LelantosNameRegistrar(OWNER, IERC20(token), FEE, TREASURY, new string[](0), address(0));
        deal(token, address(clone), FEE);
        // A treasury that already holds the token, as a live one does.
        deal(token, TREASURY, 1);

        clone.run(
            token,
            abi.encodeCall(IERC20.approve, (address(paid), FEE)),
            address(paid),
            abi.encodeCall(LelantosNameRegistrar.register, (LABEL, VALUE, vm.addr(CONTROLLER_KEY)))
        );
        uint256 used = vm.lastCallGas().gasTotalUsed;
        assertFalse(paid.available(LABEL), "registered");
        return used;
    }

    function test_gas_usdcStaysWithinTheFeeTokenPremium() public {
        uint256 plain = _feeLegGas(address(new MockERC20("Plain", "PLN", 6)));
        uint256 usdc = _feeLegGas(USDC);
        emit log_named_uint("plain ERC-20 fee leg", plain);
        emit log_named_uint("mainnet USDC fee leg", usdc);
        assertLe(usdc, plain + FEE_TOKEN_PREMIUM, "USDC costs more than REGISTER_MIN_GAS allows for");
    }
}
