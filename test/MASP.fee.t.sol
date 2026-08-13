// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { FeeConfig } from "../src/FeeConfig.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";

/// `setFeeBps` and the constructor must reject `feeBps > MAX_FEE_BPS`.
/// Without this guard the unshield path underflow-reverts on `outAmt - fee`
/// (DoS) and the shield path overcharges the payer beyond principal (silent
/// economic loss). MAX_FEE_BPS is the anti-rug ceiling (20%).
contract MASPFeeBoundTest is Test {
    uint16 internal constant BPS = 2_000;

    Groth16Verifier verifier;
    TreeUpdateBatchGroth16Verifier tubVerifier;
    address permit2;
    MASP masp;

    function setUp() public {
        verifier = new Groth16Verifier();
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        masp = _deploy(0);
    }

    function _deploy(uint16 fee) internal returns (MASP) {
        return new MASP(
            IVerifier(address(verifier)),
            IVerifier(address(tubVerifier)),
            ISignatureTransfer(address(permit2)),
            new uint64[](0),
            new IERC20[](0),
            new uint256[](0),
            fee,
            address(0xfee),
            address(this)
        );
    }

    function testSetFeeBpsAcceptsAtBound() public {
        masp.setFeeBps(BPS);
        assertEq(masp.feeBps(), BPS);
    }

    function testSetFeeBpsRejectsAboveBound() public {
        vm.expectRevert(FeeConfig.FeeTooHigh.selector);
        masp.setFeeBps(BPS + 1);
    }

    function testSetFeeBpsRejectsUint16Max() public {
        vm.expectRevert(FeeConfig.FeeTooHigh.selector);
        masp.setFeeBps(type(uint16).max);
    }

    function testConstructorAcceptsFeeAtBound() public {
        MASP m = _deploy(BPS);
        assertEq(m.feeBps(), BPS);
    }

    function testConstructorRejectsFeeAboveBound() public {
        vm.expectRevert(FeeConfig.FeeTooHigh.selector);
        _deploy(BPS + 1);
    }

    function testFuzz_SetFeeBpsBounds(uint16 fee) public {
        if (fee > BPS) {
            vm.expectRevert(FeeConfig.FeeTooHigh.selector);
            masp.setFeeBps(fee);
        } else {
            masp.setFeeBps(fee);
            assertEq(masp.feeBps(), fee);
        }
    }
}
