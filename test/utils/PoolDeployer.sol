// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";
import { BatchedGroth16Verifier } from "../../src/verifiers/BatchedGroth16Verifier.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { uniformBps } from "./FeeArrays.sol";

import { MASP } from "../../src/MASP.sol";
import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";

// Default proxy wiring for suites that do not exercise the upgrade surface.
// Those that do build their own proxy to control the admin, window and pause
// ceiling.
address constant TEST_PROXY_ADMIN = address(0x9403);
uint256 constant TEST_UPGRADE_DELAY = 30 days;
uint256 constant TEST_MAX_PAUSE = 7 days;

/// The bare logic contract. Deployed separately by tests asserting that
/// initialization rejects bad parameters, so its `CREATE` does not consume
/// `vm.expectRevert` before the proxy construction that runs `initialize`.
function newPoolImplementation() returns (MASP) {
    return new MASP();
}

/// Init calldata for the pool. Shared by `deployPool` and by harnesses, which
/// subclass `MASP` and cannot use it.
function poolInitCalldata(
    IVerifier treeUpdateBatchVerifier_,
    IBatchVerifier spendVerifier_,
    ISignatureTransfer permit2_,
    uint64[] memory ids,
    IERC20[] memory tokens,
    uint256[] memory scales,
    uint16[] memory depositBps,
    uint16[] memory withdrawBps,
    address treasury_,
    address owner_
) pure returns (bytes memory) {
    return abi.encodeCall(
        MASP.initialize,
        (
            treeUpdateBatchVerifier_,
            spendVerifier_,
            permit2_,
            ids,
            tokens,
            scales,
            depositBps,
            withdrawBps,
            treasury_,
            owner_
        )
    );
}

/// Puts an already-deployed implementation behind the standard test proxy.
function deployBehindProxy(address impl, bytes memory initData) returns (address) {
    return address(new DelayedUpgradeProxy(impl, initData, TEST_PROXY_ADMIN, TEST_UPGRADE_DELAY, TEST_MAX_PAUSE));
}

/// Deploys an implementation behind a proxy and initializes it through the
/// proxy. `MASP`'s constructor calls `_disableInitializers()`, so a directly
/// deployed implementation cannot be initialized.
function deployPool(
    IVerifier treeUpdateBatchVerifier_,
    IBatchVerifier spendVerifier_,
    ISignatureTransfer permit2_,
    uint64[] memory ids,
    IERC20[] memory tokens,
    uint256[] memory scales,
    uint16[] memory depositBps,
    uint16[] memory withdrawBps,
    address treasury_,
    address owner_
) returns (MASP) {
    bytes memory initData = poolInitCalldata(
        treeUpdateBatchVerifier_,
        spendVerifier_,
        permit2_,
        ids,
        tokens,
        scales,
        depositBps,
        withdrawBps,
        treasury_,
        owner_
    );
    return MASP(deployBehindProxy(address(newPoolImplementation()), initData));
}

// ---------------------------------------------------------------------------
// Verifier stacks
//
// Five groups of suites were each rebuilding one of these two wirings verbatim
// in their own `setUp`. Kept as free functions returning the pieces, rather
// than as a base contract, so a suite still states which pool it deploys and
// with what registry — that choice is usually part of what it is testing.
// ---------------------------------------------------------------------------

/// Verifiers that accept nothing, for suites whose subject is reached before
/// any proof is checked — guard ordering, request validation, bookkeeping.
///
/// The two `IVerifier` slots only have to carry code: `MASP.initialize` rejects
/// a codeless verifier, and a `MockERC20` is a convenient contract that is
/// certainly not one. `MockBatchVerifier` answers `false` until told otherwise,
/// so a test that accidentally reaches proof verification fails rather than
/// passing on an unchecked proof.
/// `bv` is returned concretely rather than as `IBatchVerifier`: suites that
/// reach proof verification need `setResult` to say what the verifier answers,
/// and the concrete type still passes wherever the interface is expected.
function mockVerifierStack() returns (IVerifier tub, MockBatchVerifier bv, ISignatureTransfer permit2) {
    tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
    bv = new MockBatchVerifier();
    permit2 = ISignatureTransfer(new DeployPermit2().deployPermit2());
}

/// The real Groth16 verifiers and a real Permit2, for suites that carry a
/// bundled proof and need it to verify end to end.
function realVerifierStack() returns (IVerifier tub, IBatchVerifier bv, ISignatureTransfer permit2) {
    tub = IVerifier(address(new TreeUpdateBatchGroth16Verifier()));
    bv = IBatchVerifier(address(new BatchedGroth16Verifier()));
    permit2 = ISignatureTransfer(new DeployPermit2().deployPermit2());
}

/// The single-asset registry arrays every one-token suite was building by hand.
function singleAsset(IERC20 token, uint64 id, uint256 scale)
    pure
    returns (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales)
{
    ids = new uint64[](1);
    tokens = new IERC20[](1);
    scales = new uint256[](1);
    ids[0] = id;
    tokens[0] = token;
    scales[0] = scale;
}

/// The empty registry, for suites that register their assets later or not at
/// all. Spelled out because `new uint64[](0)` three times reads as an accident.
function noAssets() pure returns (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) {
    ids = new uint64[](0);
    tokens = new IERC20[](0);
    scales = new uint256[](0);
}

/// A two-asset registry at a shared scale. Second only to `singleAsset` in how
/// often it was spelled out by hand.
function twoAssets(IERC20 tokenA, uint64 idA, IERC20 tokenB, uint64 idB, uint256 scale)
    pure
    returns (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales)
{
    ids = new uint64[](2);
    tokens = new IERC20[](2);
    scales = new uint256[](2);
    ids[0] = idA;
    tokens[0] = tokenA;
    scales[0] = scale;
    ids[1] = idB;
    tokens[1] = tokenB;
    scales[1] = scale;
}

/// `deployPool` with one fee rate applied to both legs of every asset, which
/// is what all but a handful of suites want. Those that set the legs apart —
/// or vary the rate per asset — still call `deployPool` with arrays they built.
function deployPoolUniform(
    IVerifier treeUpdateBatchVerifier_,
    IBatchVerifier spendVerifier_,
    ISignatureTransfer permit2_,
    uint64[] memory ids,
    IERC20[] memory tokens,
    uint256[] memory scales,
    uint16 bps,
    address treasury_,
    address owner_
) returns (MASP) {
    return deployPool(
        treeUpdateBatchVerifier_,
        spendVerifier_,
        permit2_,
        ids,
        tokens,
        scales,
        uniformBps(ids.length, bps),
        uniformBps(ids.length, bps),
        treasury_,
        owner_
    );
}
