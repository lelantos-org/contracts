// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASPTestBase } from "../utils/MASPTestBase.sol";
import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";

/// Conformance of `IMASPPool` to `MASP`.
///
/// `IMASPPool` is hand-written, and Solidity does not check it against the
/// contract it describes: a drifted signature compiles on both sides and fails
/// only at runtime, as a call to a selector the pool does not implement. For
/// `cancelDeposit` that would make `SwapWrapper.cancelEscrow`, the only
/// recovery path for a swap escrow, undispatchable.
///
/// Two layers. The selector assertions compare the interface's selectors with
/// MASP's. The dispatch tests call the real pool through the interface and
/// expect a named MASP error: a wrong selector on a contract with no fallback
/// reverts with empty returndata, so MASP's own error shows the call reached
/// the function body.
contract IMASPPoolTest is MASPTestBase {
    // --- selectors: every selector matches MASP's ----------------------------

    function test_selector_withdraw() public pure {
        assertEq(IMASPPool.withdraw.selector, MASP.withdraw.selector, "withdraw drifted");
    }

    function test_selector_depositAuthorized() public pure {
        assertEq(IMASPPool.depositAuthorized.selector, MASP.depositAuthorized.selector, "depositAuthorized drifted");
    }

    function test_selector_cancelDeposit() public pure {
        assertEq(IMASPPool.cancelDeposit.selector, MASP.cancelDeposit.selector, "cancelDeposit drifted");
    }

    /// The selector tests above show only that the interface and the pool
    /// agree; these pin `depositAuthorized` and `cancelDeposit` to the argument
    /// lists written out, so a change made to the pool and the interface
    /// together still has to be made here, where an off-chain caller reads it.
    /// A deposit describes each note by its asset, amount and `inner`; a cancel
    /// resupplies the escrow preimage, closed by the three-word fee note and
    /// the refund cap.
    function test_signature_depositAuthorized() public pure {
        string memory request = "(uint256,uint64,uint64,address,address,bytes32,uint64,uint64,bytes32)";
        string memory aux = "(uint256,uint256,uint256,uint256,uint256,uint256,bytes)";
        assertEq(
            IMASPPool.depositAuthorized.selector,
            bytes4(keccak256(bytes(string.concat("depositAuthorized(", request, ",", aux, ",", aux, ")")))),
            "depositAuthorized argument types drifted"
        );
    }

    function test_signature_cancelDeposit() public pure {
        assertEq(
            IMASPPool.cancelDeposit.selector,
            bytes4(
                keccak256(
                    "cancelDeposit(uint256,uint48,bytes32,uint64,uint16,address,uint32,(uint48,uint64,bytes32),uint256)"
                )
            ),
            "cancelDeposit argument types drifted"
        );
    }

    function test_selector_asset() public pure {
        assertEq(IMASPPool.asset.selector, AssetRegistry.asset.selector, "asset drifted");
    }

    function test_selector_isYieldAsset() public view {
        assertEq(IMASPPool.isYieldAsset.selector, bytes4(keccak256("isYieldAsset(uint64)")), "isYieldAsset drifted");
        assertTrue(!MASP(address(masp)).isYieldAsset(1), "isYieldAsset dispatches");
    }

    /// `withdrawNative` forwards its own argument bytes under `withdraw`'s
    /// selector, which is sound only while the two take identical arguments.
    function test_withdrawNative_sharesWithdrawArguments() public pure {
        assertEq(
            NativeAdapter.withdrawNative.selector,
            bytes4(keccak256(bytes(_withdrawSignature("withdrawNative")))),
            "withdrawNative argument types drifted from withdraw"
        );
        assertEq(
            IMASPPool.withdraw.selector, bytes4(keccak256(bytes(_withdrawSignature("withdraw")))), "withdraw drifted"
        );
    }

    function _withdrawSignature(string memory name) internal pure returns (string memory) {
        string memory proof = "(uint256[2],uint256[2][2],uint256[2])";
        // merkleRoot, nullifier, outCm, publicAssetId, publicOut, digest, then
        // recipient, chainId, payer, relayer, intentHash.
        string memory transact =
            "(bytes32,bytes32[4],bytes32[6],uint64,uint64,uint256,address,uint256,address,address,uint256)";
        // newRoot, startIndex, anchorIndex, digest.
        string memory spendTree = "(bytes32,uint64,uint8,uint256)";
        return string.concat(
            name,
            "(",
            proof,
            ",",
            transact,
            ",",
            proof,
            ",",
            spendTree,
            ",(uint256,uint256,uint256,uint256,uint256,uint256,bytes)[6])"
        );
    }

    /// `escrowed` is a public mapping on MASP, and a getter synthesised from a
    /// state variable has no `.selector` on the contract type. The signature
    /// literal stands in; the dispatch test below pins it to the deployed pool.
    function test_selector_escrowed() public pure {
        assertEq(IMASPPool.escrowed.selector, bytes4(keccak256("escrowed(uint256)")), "escrowed drifted");
    }

    // --- runtime: the real pool answers each one ----------------------------

    function _pool() internal view returns (IMASPPool) {
        return IMASPPool(address(masp));
    }

    function test_dispatch_escrowed() public view {
        assertEq(_pool().escrowed(0), bytes32(0), "unknown id reads as the zero sentinel");
    }

    /// An unknown id suffices: `DepositNotPending` is the first check in
    /// `cancelDeposit`, so reaching it shows dispatch succeeded.
    function test_dispatch_cancelDeposit() public {
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, uint256(999)));
        _pool()
            .cancelDeposit(
                999,
                0,
                bytes32(0),
                0,
                0,
                address(0),
                0,
                PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeInner: bytes32(0) }),
                0
            );
    }

    function test_dispatch_depositAuthorized() public {
        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid + 1; // first check in `_validateDeposit`
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();

        vm.expectRevert(MASP.BadChainId.selector);
        _pool().depositAuthorized(d, aux[0], aux[1]);
    }

    function test_dispatch_withdraw() public {
        // `publicOut` is left zero: the first check in `withdraw`.
        PubInputs.Transact memory pi;
        IMASPPool.Proof memory proof;
        PubInputs.SpendTree memory tpi;

        vm.expectRevert(MASP.MustHaveWithdraw.selector);
        _pool().withdraw(proof, pi, proof, tpi, SpendFixture.validAux());
    }

    function test_dispatch_asset() public view {
        IMASPPool.AssetEntry memory viaInterface = _pool().asset(ASSET_ID);
        assertEq(viaInterface.token, address(masp.asset(ASSET_ID).token), "token");
        assertEq(viaInterface.scale, masp.asset(ASSET_ID).scale, "scale");
        // The interface restates the struct, so the two must encode alike field
        // for field, the yield flag included.
        assertEq(abi.encode(viaInterface), abi.encode(masp.asset(ASSET_ID)), "AssetEntry is not ABI-identical");
    }
}
