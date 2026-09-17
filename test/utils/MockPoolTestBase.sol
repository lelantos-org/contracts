// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { SpendFixture } from "./SpendFixture.sol";
import { deployPoolUniform, mockVerifierStack } from "./PoolDeployer.sol";
import { TestConstants } from "./TestConstants.sol";

/// Shared state and spend scaffolding for MASP suites run against the mock
/// verifier stack (`mockVerifierStack`), whose subject is reached without a
/// real proof.
///
/// There is no `setUp`. Which registry, fee, owner and pool contract a suite
/// deploys, and in what order relative to its tokens, is usually part of what
/// it tests, so each suite keeps its own `setUp` and calls `_deployMockPool` or
/// `_deployMockStack` from it.
///
/// `FEE_BPS` and the spend payer are not declared here: their values differ
/// between suites, and Solidity forbids a derived contract redeclaring a
/// constant, so a base default would force one value on every suite.
abstract contract MockPoolTestBase is Test {
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 internal constant SCALE = TestConstants.SCALE;
    address internal constant TREASURY = TestConstants.TREASURY;
    address internal constant OWNER = TestConstants.OWNER;
    address internal constant RELAYER = TestConstants.RELAYER;
    address internal constant RECIPIENT = TestConstants.RECIPIENT;

    /// The tree-update verifier slot: a contract with code but no
    /// `verifyProof`, so a flush fails unless a suite mocks the answer.
    IVerifier internal tub;
    /// Rejects every batch until `setResult(true)`, so a spend that reaches
    /// verification unintentionally fails instead of passing unchecked.
    MockBatchVerifier internal bv;
    ISignatureTransfer internal permit2;
    /// The pool under test. A suite on a harness subclass keeps a second,
    /// concretely typed handle to the same address for the harness-only calls,
    /// so the helpers here work for both.
    MASP internal masp;
    /// The registered token of suites that register one. Created by the suite,
    /// which decides where in `setUp` it is deployed.
    MockERC20 internal token;

    /// Deploys the mock verifier stack into `tub`, `bv` and `permit2`, for
    /// suites that put their own pool contract on top of it.
    function _deployMockStack() internal {
        (tub, bv, permit2) = mockVerifierStack();
    }

    /// `_deployMockStack`, then a `MASP` behind the test proxy with one fee
    /// rate on both legs of every asset in the registry.
    function _deployMockPool(
        uint64[] memory ids,
        IERC20[] memory tokens,
        uint256[] memory scales,
        uint16 bps,
        address treasury_,
        address owner_
    ) internal {
        _deployMockStack();
        masp = deployPoolUniform(tub, bv, permit2, ids, tokens, scales, bps, treasury_, owner_);
    }

    /// A spend request that passes the party, nullifier and anchor checks of
    /// `_validateRequest`: bound to this chain and `RECIPIENT`, with distinct
    /// nullifiers and commitments from the seeds, and anchored at the current
    /// root. Asset and public amounts stay zero; callers set them, and change
    /// whichever field their test is about.
    function _transact(address payer_, address relayer_, uint256 nullifierSeed, uint256 outCmSeed)
        internal
        view
        returns (PubInputs.Transact memory pi)
    {
        pi.chainId = block.chainid;
        pi.recipient = RECIPIENT;
        pi.payer = payer_;
        pi.relayer = relayer_;
        SpendFixture.fillOutputs(pi, nullifierSeed, outCmSeed);
        pi.merkleRoot = masp.currentRoot();
    }

    /// The tree-update argument paired with `pi`, at the tree frontier and
    /// anchored at `pi.merkleRoot`'s ring slot. An unknown root gets slot 0, so
    /// a test tampering with the root still reaches the anchor check.
    function _spendTree(PubInputs.Transact memory pi) internal view returns (PubInputs.SpendTree memory) {
        (, uint256 anchorIndex) = masp.rootIndexOf(pi.merkleRoot);
        return SpendFixture.spendTree(bytes32(uint256(0xdead)), masp.committedCount(), uint8(anchorIndex));
    }
}
