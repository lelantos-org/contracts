// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { BatchedGroth16Verifier } from "../src/verifiers/BatchedGroth16Verifier.sol";
import { IBatchVerifier } from "../src/interfaces/IBatchVerifier.sol";
import { SpendFixture } from "./utils/SpendFixture.sol";
import { uniformBps } from "./utils/FeeArrays.sol";

/// `depositAuthorized` — Permit2 AllowanceTransfer-based deposit.
/// Tests use `IAllowanceTransfer.approve` from the payer to set up the
/// allowance window directly (production uses a pre-signed PermitSingle,
/// equivalent on-chain state).
contract MASPDepositAuthorizedTest is Test {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);
    TreeUpdateBatchGroth16Verifier tubVerifier;
    BatchedGroth16Verifier batchVerifier;
    address permit2;
    MockERC20 token;
    MASP masp;

    address payer = address(0xa11ce);
    address recipient = address(0xb0b);

    function setUp() public {
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        batchVerifier = new BatchedGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("M", "M", 18);

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = ASSET_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;

        masp = new MASP(
            IVerifier(address(tubVerifier)),
            IBatchVerifier(address(batchVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            uniformBps(ids.length, FEE_BPS),
            uniformBps(ids.length, FEE_BPS),
            TREASURY,
            OWNER
        );

        // Real EOA payer: needs ERC20 → Permit2 max approve once.
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);
    }

    function _request(uint64 publicIn, address payerAddr, bytes32 salt)
        internal
        view
        returns (PubInputs.DepositRequest memory d)
    {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = payerAddr;
        d.recipient = recipient;
        d.outCm = keccak256(abi.encode(salt, "cm0"));
        d.feeCm = bytes32(uint256(0xfee));
    }

    function _aux() internal pure returns (AuxValidation.Output[6] memory aux) {
        return SpendFixture.validAux();
    }

    function _total(uint64 publicIn) internal pure returns (uint256) {
        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        return inAmt + fee;
    }

    function _setupAllowance(uint160 cap, uint48 expiration) internal {
        vm.prank(payer);
        IAllowanceTransfer(address(permit2)).approve(address(token), address(masp), cap, expiration);
    }

    function testHappyPathPullsViaAllowance() public {
        uint64 amt = 100;
        uint256 total = _total(amt);
        token.mint(payer, total * 5);
        _setupAllowance(uint160(total * 5), uint48(block.timestamp + 1 days));

        uint256 poolBefore = token.balanceOf(address(masp));

        PubInputs.DepositRequest memory d = _request(amt, payer, bytes32(uint256(1)));
        AuxValidation.Output[6] memory aux = _aux();

        vm.prank(payer);
        uint256 id = masp.depositAuthorized(d, aux[0], aux[1]);

        assertEq(id, 0);
        assertEq(token.balanceOf(address(masp)) - poolBefore, total, "MASP credited");
        (uint160 remaining,,) = IAllowanceTransfer(address(permit2)).allowance(payer, address(token), address(masp));
        assertEq(remaining, uint160(total * 5) - uint160(total), "allowance decremented");
    }

    function testRepeatDepositsConsumeSameAllowance() public {
        uint64 amt = 50;
        uint256 total = _total(amt);
        token.mint(payer, total * 4);
        _setupAllowance(uint160(total * 3), uint48(block.timestamp + 1 days));

        AuxValidation.Output[6] memory aux = _aux();
        for (uint256 i; i < 3; i++) {
            PubInputs.DepositRequest memory d = _request(amt, payer, bytes32(i + 1));
            vm.prank(payer);
            masp.depositAuthorized(d, aux[0], aux[1]);
        }
        // Fourth deposit must fail: allowance exhausted.
        PubInputs.DepositRequest memory d4 = _request(amt, payer, bytes32(uint256(4)));
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, uint160(0)));
        masp.depositAuthorized(d4, aux[0], aux[1]);
    }

    function testRevertsOnExpiredAllowance() public {
        uint64 amt = 100;
        uint256 total = _total(amt);
        token.mint(payer, total);
        uint48 exp = uint48(block.timestamp + 1 hours);
        _setupAllowance(uint160(total), exp);

        vm.warp(uint256(exp) + 1);

        PubInputs.DepositRequest memory d = _request(amt, payer, bytes32(uint256(1)));
        AuxValidation.Output[6] memory aux = _aux();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, uint256(exp)));
        masp.depositAuthorized(d, aux[0], aux[1]);
    }

    function testRevertsOnSenderNotPayer() public {
        uint64 amt = 100;
        uint256 total = _total(amt);
        token.mint(payer, total);
        _setupAllowance(uint160(total), uint48(block.timestamp + 1 days));

        PubInputs.DepositRequest memory d = _request(amt, payer, bytes32(uint256(1)));
        AuxValidation.Output[6] memory aux = _aux();

        address other = address(0xdead);
        vm.prank(other);
        vm.expectRevert(MASP.PayerNotSender.selector);
        masp.depositAuthorized(d, aux[0], aux[1]);
    }

    function testRevertsOnNoAllowance() public {
        uint64 amt = 100;
        token.mint(payer, _total(amt));
        // No allowance set up.

        PubInputs.DepositRequest memory d = _request(amt, payer, bytes32(uint256(1)));
        AuxValidation.Output[6] memory aux = _aux();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, uint256(0)));
        masp.depositAuthorized(d, aux[0], aux[1]);
    }
}
