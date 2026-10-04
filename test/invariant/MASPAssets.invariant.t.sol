// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MASPHarness, deployHarness } from "../utils/MASPHarness.sol";

/// Handler drives `addAsset` + `setAssetDisabled` with fuzz-generated inputs.
/// Tracks the registered id set as a ghost array so invariants can cross-check
/// `masp.asset(id)`. The registry is add-only: a registered id remains
/// resolvable.
///
/// Id 0 is the one id that can never join that set. It means "no asset" to the
/// circuits (a transfer's `publicAssetId`, a zero-value fee note's
/// `feeAssetId`), so `_addAsset` refuses it with `ZeroAssetId`. `addAsset`
/// reaches it only when the fuzzer draws 0, so `addZeroAsset` asks for it on
/// every call.
contract AssetsHandler is Test {
    MASPHarness public masp;
    uint64[] public ghostIds;
    /// Registrations of id 0 attempted, whether any landed, and whether any
    /// was refused by something other than `ZeroAssetId`.
    uint256 public zeroIdAttempts;
    bool public zeroIdAccepted;
    bool public zeroIdRefusedOtherwise;

    constructor(MASPHarness m) {
        masp = m;
    }

    function addAsset(uint64 rawId) external {
        if (rawId == 0) {
            _addZeroAsset(1);
            return;
        }
        IERC20 tok = IERC20(address(new MockERC20("M", "M", 18)));
        try masp.addAsset(rawId, tok, 1, 0, 0) {
            ghostIds.push(rawId);
        } catch {
            // Duplicate id — ghost unchanged.
        }
    }

    /// Registers id 0 with arguments every other guard accepts, so only
    /// `ZeroAssetId` can refuse it.
    function addZeroAsset(uint48 scale) external {
        _addZeroAsset(scale == 0 ? 1 : scale);
    }

    function _addZeroAsset(uint256 scale) internal {
        IERC20 tok = IERC20(address(new MockERC20("M", "M", 18)));
        zeroIdAttempts += 1;
        try masp.addAsset(0, tok, scale, 0, 0) {
            zeroIdAccepted = true;
            ghostIds.push(0);
        } catch (bytes memory err) {
            // The id is the first thing `_addAsset` checks. Recorded for the
            // invariant to assert: under `fail_on_revert = false` an assertion
            // failing here would only discard the call.
            if (bytes4(err) != AssetRegistry.ZeroAssetId.selector) zeroIdRefusedOtherwise = true;
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
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        MockBatchVerifier bv = new MockBatchVerifier();
        address permit2 = new DeployPermit2().deployPermit2();
        masp = deployHarness(tub, bv, ISignatureTransfer(address(permit2)), address(0xfee), address(this));
        handler = new AssetsHandler(masp);
        masp.transferOwnership(address(handler));
        targetContract(address(handler));
    }

    /// Every successfully added id remains resolvable (`asset` does not
    /// revert). The registry is add-only, so no admin action strands an
    /// outstanding note.
    function invariant_AllAddedIdsRemainLive() public view {
        uint256 n = handler.ghostIdsLength();
        for (uint256 i; i < n; ++i) {
            masp.asset(handler.ghostIdAt(i));
        }
    }

    /// Asset id 0 is never registered: no registration of it lands, and the
    /// registry holds no token under it after any sequence of owner calls.
    ///
    /// The pool leans on this in two places. `transfer` requires
    /// `publicAssetId == 0` and looks no asset up, and a zero-value relayer
    /// note must name asset 0; both read 0 as "no asset", which only holds
    /// while nothing is registered there.
    function invariant_ZeroIdNeverRegistered() public view {
        assertFalse(handler.zeroIdAccepted(), "a registration of id 0 landed");
        assertFalse(handler.zeroIdRefusedOtherwise(), "id 0 refused for another reason than ZeroAssetId");
        try masp.asset(0) {
            revert("id 0 resolves to an asset");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(0)), "id 0 lookup");
        }
    }

    /// The handler reaches the id-0 guard, so the invariant above does not hold
    /// vacuously.
    function test_handlerReachesZeroIdGuard() public {
        handler.addZeroAsset(7);
        handler.addAsset(0);
        assertEq(handler.zeroIdAttempts(), 2, "both handlers attempted id 0");
        assertFalse(handler.zeroIdAccepted(), "id 0 refused");
        assertFalse(handler.zeroIdRefusedOtherwise(), "and by ZeroAssetId");
        assertEq(handler.ghostIdsLength(), 0, "nothing registered");

        // A non-zero id with the same arguments registers, so the refusal above
        // is about the id.
        handler.addAsset(1);
        assertEq(handler.ghostIdsLength(), 1, "id 1 registered");
    }
}
