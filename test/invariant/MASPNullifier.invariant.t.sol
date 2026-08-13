// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { NullifierSet } from "../../src/NullifierSet.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { MASPHarness } from "./MASPHarness.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// Handler exposes a single bounded entrypoint that consumes random nullifiers
/// and tracks ghost state for cross-checking against on-chain `spent`.
contract NullifierHandler is Test {
    MASPHarness public masp;
    mapping(bytes32 => bool) public ghostConsumed;
    bytes32[] public consumedList;
    uint256 public successCount;
    uint256 public doubleSpendCount;

    constructor(MASPHarness m) {
        masp = m;
    }

    /// Consume a random nullifier. The handler chooses with probability ~1/4
    /// to retry an already-consumed nullifier so the DoubleSpend branch is
    /// exercised proportionally instead of vanishingly.
    function consume(bytes32 nf, uint8 reuseSeed) external {
        if (consumedList.length > 0 && reuseSeed % 4 == 0) {
            nf = consumedList[uint256(uint8(reuseSeed)) % consumedList.length];
        }

        if (ghostConsumed[nf]) {
            // Must revert with DoubleSpend.
            try masp.consumeNullifierExternal(nf) {
                revert("expected DoubleSpend, got success");
            } catch (bytes memory reason) {
                bytes4 selector;
                assembly {
                    selector := mload(add(reason, 0x20))
                }
                require(selector == NullifierSet.DoubleSpend.selector, "wrong revert reason");
                doubleSpendCount++;
            }
            return;
        }

        masp.consumeNullifierExternal(nf);
        ghostConsumed[nf] = true;
        consumedList.push(nf);
        successCount++;
    }

    function consumedAt(uint256 i) external view returns (bytes32) {
        return consumedList[i];
    }

    function consumedLength() external view returns (uint256) {
        return consumedList.length;
    }
}

contract MASPNullifierInvariantTest is StdInvariant, Test {
    MASPHarness masp;
    NullifierHandler handler;

    function setUp() public {
        IVerifier v = IVerifier(address(new MockERC20("v", "v", 18)));
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        address permit2 = new DeployPermit2().deployPermit2();
        masp = new MASPHarness(v, tub, ISignatureTransfer(address(permit2)), address(0xfee), address(this));
        handler = new NullifierHandler(masp);
        targetContract(address(handler));
    }

    /// Every nullifier the handler successfully consumed must read as spent.
    function invariant_ConsumedAreSpent() public view {
        uint256 n = handler.consumedLength();
        for (uint256 i; i < n; ++i) {
            bytes32 nf = handler.consumedAt(i);
            assertTrue(masp.spent(nf), "consumed nf not spent");
        }
    }

    /// successCount equals the size of the deduplicated consumed list.
    function invariant_SuccessCountMatchesList() public view {
        assertEq(handler.successCount(), handler.consumedLength());
    }
}
