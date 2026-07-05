// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { MASPHarness } from "./MASPHarness.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// Handler drives `addAsset` + `setAssetDisabled` with fuzz-generated inputs.
/// Tracks the live id set as a ghost array so invariants can cross-check
/// `masp.asset(id)`. The registry is add-only: once an id is registered it
/// must remain resolvable.
contract AssetsHandler is Test {
    MASPHarness public masp;
    uint64[] public ghostIds;

    constructor(MASPHarness m) {
        masp = m;
    }

    function addAsset(uint64 rawId) external {
        IERC20 tok = IERC20(address(new MockERC20("M", "M", 18)));
        try masp.addAsset(rawId, tok, 1) {
            ghostIds.push(rawId);
        } catch {
            // Duplicate / zero / not-owner — ghost unchanged.
        }
    }

    function setAssetDisabled(uint64 rawId, bool disabled) external {
        try masp.setAssetDisabled(rawId, disabled) {
        // Disable flag does not affect the live-id set; nothing to record.
        }
            catch {
            // Unknown id — ghost unchanged.
        }
    }

    function ghostIdsLength() external view returns (uint256) {
        return ghostIds.length;
    }

    function ghostIdAt(uint256 i) external view returns (uint64) {
        return ghostIds[i];
    }
}

contract MASPAssetsInvariantTest is StdInvariant, Test {
    MASPHarness masp;
    AssetsHandler handler;

    function setUp() public {
        IVerifier v = IVerifier(address(new MockERC20("v", "v", 18)));
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        address permit2 = new DeployPermit2().deployPermit2();
        masp = new MASPHarness(v, tub, ISignatureTransfer(address(permit2)), address(0xfee), address(this));
        handler = new AssetsHandler(masp);
        masp.transferOwnership(address(handler));
        targetContract(address(handler));
    }

    /// Every id ever successfully added must remain resolvable — the registry
    /// is add-only, so no admin action can strand an outstanding note.
    function invariant_AllAddedIdsRemainLive() public view {
        uint256 n = handler.ghostIdsLength();
        for (uint256 i; i < n; ++i) {
            masp.asset(handler.ghostIdAt(i));
        }
    }
}
