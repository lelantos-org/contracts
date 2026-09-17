// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";
import { MASP } from "../../src/MASP.sol";
import { CommitmentTree } from "../../src/CommitmentTree.sol";
import { Bundler } from "../../src/bundler/Bundler.sol";
import { BundlerFactory } from "../../src/bundler/BundlerFactory.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { SwapIntent } from "../swap/SwapIntent.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MockSwapAdapter } from "../swap/mocks/MockSwapAdapter.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";
import { FeeMath } from "../utils/FeeMath.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { deployPoolUniform } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// `Bundler` against a real pool and real adapters. Proof verification is
/// mocked to accept, as in the other pool suites: what is under test is that
/// chained tree positions land in one transaction, that each call's submitter
/// binding holds through the Bundler, and that execution stops at the first
/// failure.
abstract contract BundlerTestBase is Test {
    uint64 internal constant ASSET_A = 1; // plain ERC-20, spent and swapped from
    uint64 internal constant ASSET_WETH = 2; // wrapped native, withdrawn natively
    uint64 internal constant ASSET_B = 3; // plain ERC-20, swapped into
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;
    address internal constant RECIPIENT = TestConstants.RECIPIENT;

    address internal constant BUNDLER_OWNER = address(0xB0551);
    address internal constant OTHER_OWNER = address(0x0712E7);
    address internal constant OPERATOR = address(0x0FE7A70);
    address internal constant SPEND_PAYER = address(0x9A7E7);
    address internal constant NATIVE_RECIPIENT = address(0xE7E7);
    /// Escrow payer for flushed deposits; carries a permissive ERC-1271 stub.
    address internal constant DEPOSIT_PAYER = TestConstants.ESCROW_PAYER;
    uint64 internal constant DEPOSIT_UNITS = 100;
    bytes32 internal constant DEPOSIT_CM = bytes32(uint256(0xd0));
    bytes32 internal constant FEE_CM = DepositFixture.FEE_CM;
    address internal constant SWAP_REFUND_TO = TestConstants.SWAP_REFUND_TO;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockWETH9 internal weth;
    address internal permit2;
    MockBatchVerifier internal bv;
    MASP internal masp;
    NativeAdapter internal nativeAdapter;
    SwapWrapper internal wrapper;
    GenericCallWrapper internal generic;
    MockSwapAdapter internal swapAdapter;
    BundlerFactory internal factory;
    Bundler internal bundler;

    /// A root every spend in these tests proves membership against, and its
    /// ring slot.
    bytes32 internal anchor;
    uint8 internal anchorIndex;

    function setUp() public {
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        weth = new MockWETH9();
        permit2 = new DeployPermit2().deployPermit2();

        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        bv = new MockBatchVerifier();

        uint64[] memory ids = new uint64[](3);
        IERC20[] memory tokens = new IERC20[](3);
        uint256[] memory scales = new uint256[](3);
        (ids[0], tokens[0], scales[0]) = (ASSET_A, IERC20(address(tokenA)), SCALE);
        (ids[1], tokens[1], scales[1]) = (ASSET_WETH, IERC20(address(weth)), SCALE);
        (ids[2], tokens[2], scales[2]) = (ASSET_B, IERC20(address(tokenB)), SCALE);

        masp = deployPoolUniform(
            tub, bv, ISignatureTransfer(permit2), ids, tokens, scales, FEE_BPS, TREASURY, address(this)
        );
        Stubs.acceptAllProofs(masp.TREE_UPDATE_BATCH_VERIFIER(), bv);

        nativeAdapter =
            new NativeAdapter(IMASPPool(address(masp)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));
        wrapper = new SwapWrapper(IMASPPool(address(masp)), IAllowanceTransfer(permit2), address(this), TREASURY);
        swapAdapter = new MockSwapAdapter();
        wrapper.setAdapterAllowed(address(swapAdapter), true);
        wrapper.prepareToken(IERC20(address(tokenB)));
        wrapper.prepareToken(IERC20(address(tokenA)));

        generic = new GenericCallWrapper(IMASPPool(address(masp)), IAllowanceTransfer(permit2));

        factory = new BundlerFactory(address(masp), address(nativeAdapter), address(wrapper), address(generic));
        bundler = _createBundler(BUNDLER_OWNER);

        Stubs.installPermissiveERC1271(DEPOSIT_PAYER);
        anchor = masp.currentRoot();
        anchorIndex = uint8(masp.rootIndex());
    }

    // --- helpers -----------------------------------------------------------

    /// A Bundler owned by `owner_` and operated by `OPERATOR`.
    function _createBundler(address owner_) internal returns (Bundler) {
        return _createBundler(factory, owner_);
    }

    /// `_createBundler` from another factory.
    function _createBundler(BundlerFactory from, address owner_) internal returns (Bundler) {
        address[] memory operators = new address[](1);
        operators[0] = OPERATOR;
        vm.prank(owner_);
        return from.create(operators);
    }

    /// Gas `execute` uses for `calls`, rolled back.
    function _gasFor(Bundler.Call[] memory calls) internal returns (uint256 used) {
        uint256 snap = vm.snapshotState();
        vm.prank(OPERATOR);
        bundler.execute(calls);
        used = vm.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);
    }

    /// `_gasFor` the first of `calls` alone.
    function _gasForFirst(Bundler.Call[] memory calls) internal returns (uint256) {
        Bundler.Call[] memory first = new Bundler.Call[](1);
        first[0] = calls[0];
        return _gasFor(first);
    }

    /// `execute` from `OPERATOR` with `gasLimit`; `ok` is false if it reverted.
    function _executeWithGas(Bundler b, Bundler.Call[] memory calls, uint256 gasLimit)
        internal
        returns (bool ok, uint256 executed, bytes memory reason)
    {
        vm.prank(OPERATOR);
        bytes memory ret;
        (ok, ret) = address(b).call{ gas: gasLimit }(abi.encodeCall(Bundler.execute, (calls)));
        if (ok) (executed, reason) = abi.decode(ret, (uint256, bytes));
    }

    /// One of each item kind, chained from the live root: flush (2 leaves), then
    /// transfer, withdraw, withdrawNative and swap (6 leaves each).
    function _mixedBundle() internal returns (Bundler.Call[] memory calls, uint256 depositId, uint64 start) {
        depositId = _escrowDeposit();
        start = masp.committedCount();

        calls = new Bundler.Call[](5);
        calls[0] = _flushCall(depositId, masp.currentRoot(), _root(1), start);
        calls[1] = _transferCall(bundler, 0x100, _root(2), start + 2);
        calls[2] = _withdrawCall(bundler, 0x200, 5, _root(3), start + 8);
        calls[3] = _withdrawNativeCall(NATIVE_RECIPIENT, 0x300, 7, _root(4), start + 14);
        calls[4] = _swapCall(bundler, 0x400, _root(5), start + 20);
    }

    function _eventTag(Vm.Log memory l) internal view returns (bytes1) {
        bytes32 sig = l.topics.length == 0 ? bytes32(0) : l.topics[0];
        if (l.emitter == address(masp)) {
            if (sig == MASP.DepositFlushed.selector) return "F";
            if (sig == CommitmentTree.RootAdvanced.selector) return "R";
            if (sig == keccak256("NullifierConsumed(bytes32)")) return "N";
            if (sig == MASP.AssetMoved.selector) return "A";
            if (sig == MASP.NotePayload.selector) return "P";
            if (sig == MASP.DepositEscrowed.selector) return "E";
        } else if (l.emitter == address(nativeAdapter)) {
            if (sig == NativeAdapter.NativeWithdrawn.selector) return "W";
        } else if (l.emitter == address(wrapper)) {
            if (sig == SwapWrapper.SwapExecuted.selector) return "S";
        }
        return 0;
    }

    /// Roots must stay inside the scalar field: `PubInputs.compress` rejects an
    /// out-of-field coefficient.
    function _root(uint256 k) internal pure returns (bytes32) {
        return bytes32(uint256(0xabc000) + k);
    }

    /// Spend inputs proving membership against `anchor`, with outputs derived
    /// from `seed`.
    function _transact(
        uint64 assetId,
        uint64 publicOut,
        address recipient,
        address relayer,
        address payer,
        uint256 seed
    ) internal view returns (PubInputs.Transact memory pi) {
        pi.chainId = block.chainid;
        pi.publicAssetId = assetId;
        pi.publicOut = publicOut;
        pi.recipient = recipient;
        pi.relayer = relayer;
        pi.payer = payer;
        SpendFixture.fillOutputs(pi, seed, seed + 0x10);
        pi.merkleRoot = anchor;
    }

    function _transferCall(Bundler boundTo, uint256 seed, bytes32 newRoot, uint64 start)
        internal
        view
        returns (Bundler.Call memory)
    {
        PubInputs.Transact memory pi = _transact(ASSET_A, 0, RECIPIENT, address(boundTo), SPEND_PAYER, seed);
        PubInputs.SpendTree memory tpi = SpendFixture.spendTree(newRoot, start, anchorIndex);
        MASP.Proof memory p = FixtureLoader.emptyProof();
        return Bundler.Call({
            target: address(masp), data: abi.encodeCall(MASP.transfer, (p, pi, p, tpi, SpendFixture.validAux()))
        });
    }

    /// Mints the pool the tokens `publicOut` pays out.
    function _withdrawCall(Bundler boundTo, uint256 seed, uint64 publicOut, bytes32 newRoot, uint64 start)
        internal
        returns (Bundler.Call memory)
    {
        tokenA.mint(address(masp), uint256(publicOut) * SCALE);
        PubInputs.Transact memory pi = _transact(ASSET_A, publicOut, RECIPIENT, address(boundTo), SPEND_PAYER, seed);
        PubInputs.SpendTree memory tpi = SpendFixture.spendTree(newRoot, start, anchorIndex);
        MASP.Proof memory p = FixtureLoader.emptyProof();
        return Bundler.Call({
            target: address(masp), data: abi.encodeCall(MASP.withdraw, (p, pi, p, tpi, SpendFixture.validAux()))
        });
    }

    /// Funds the pool with the wrapped native `publicOut` pays out, unwrapped by
    /// the adapter to `payer`.
    function _withdrawNativeCall(address payer, uint256 seed, uint64 publicOut, bytes32 newRoot, uint64 start)
        internal
        returns (Bundler.Call memory)
    {
        uint256 gross = uint256(publicOut) * SCALE;
        vm.deal(address(this), gross);
        weth.deposit{ value: gross }();
        weth.transfer(address(masp), gross);

        PubInputs.Transact memory pi =
            _transact(ASSET_WETH, publicOut, address(nativeAdapter), address(nativeAdapter), payer, seed);
        PubInputs.SpendTree memory tpi = SpendFixture.spendTree(newRoot, start, anchorIndex);
        IMASPPool.Proof memory p = FixtureLoader.emptyPoolProof();
        return Bundler.Call({
            target: address(nativeAdapter),
            data: abi.encodeCall(NativeAdapter.withdrawNative, (p, pi, p, tpi, SpendFixture.validAux()))
        });
    }

    /// A swap of 1000 A for at least 990 B, bound to `boundTo`.
    function _swapCall(Bundler boundTo, uint256 seed, bytes32 newRoot, uint64 start)
        internal
        returns (Bundler.Call memory)
    {
        return _wrapperCall(SwapIntent.bind(_swapArgs(boundTo, seed, newRoot, start)));
    }

    function _wrapperCall(SwapWrapper.SwapArgs memory a) internal view returns (Bundler.Call memory) {
        return Bundler.Call({ target: address(wrapper), data: abi.encodeCall(SwapWrapper.swap, (a)) });
    }

    /// `_swapCall`'s unbound payload, with its venue funded.
    function _swapArgs(Bundler boundTo, uint256 seed, bytes32 newRoot, uint64 start)
        internal
        returns (SwapWrapper.SwapArgs memory a)
    {
        uint64 grossUnits = 1000;
        uint64 minUnits = 990;
        uint256 grossIn = uint256(grossUnits) * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint256 minOut = uint256(minUnits) * SCALE;
        uint256 actualOut = minOut + (minOut * FEE_BPS) / 10_000 + 3 * SCALE;

        tokenA.mint(address(masp), grossIn);
        tokenB.mint(address(swapAdapter), actualOut);
        swapAdapter.setNextActualOut(actualOut);

        a.tokenIn = address(tokenA);
        a.tokenOut = address(tokenB);
        a.amountIn = netIn;
        a.minOut = minOut;
        a.adapter = address(swapAdapter);
        a.route = abi.encode(uint24(500), uint160(0));
        a.deadline = type(uint256).max;

        a.p_w = FixtureLoader.emptyPoolProof();
        a.tp_w = FixtureLoader.emptyPoolProof();
        a.pi_w = _transact(ASSET_A, grossUnits, address(wrapper), address(wrapper), address(boundTo), seed);
        a.refundTo = SWAP_REFUND_TO;
        a.tpi_w = SpendFixture.spendTree(newRoot, start, anchorIndex);
        a.aux_w = SpendFixture.validAux();

        a.deposit_d.chainId = block.chainid;
        a.deposit_d.publicAssetId = ASSET_B;
        a.deposit_d.publicIn = minUnits;
        a.deposit_d.payer = address(wrapper);
        a.deposit_d.recipient = RECIPIENT;
        a.deposit_d.outCm = bytes32(seed + 0x100);
        a.deposit_d.feeCm = FEE_CM;
        a.aux_d = SpendFixture.validAux()[0];
        a.fee_aux_d = SpendFixture.validAux()[1];

        a.refund_d.chainId = block.chainid;
        a.refund_d.publicAssetId = ASSET_A;
        a.refund_d.publicIn = uint64((uint256(grossUnits) * (10_000 - 2 * uint256(FEE_BPS))) / 10_000);
        a.refund_d.payer = address(wrapper);
        a.refund_d.recipient = RECIPIENT;
        a.refund_d.outCm = bytes32(seed + 0x200);
        a.refund_d.feeCm = FEE_CM;
        a.refund_aux_d = SpendFixture.validAux()[2];
        a.refund_fee_aux_d = SpendFixture.validAux()[3];
    }

    /// Escrows a `DEPOSIT_UNITS` deposit of `DEPOSIT_CM` through Permit2 from the
    /// ERC-1271 payer.
    function _escrowDeposit() internal returns (uint256 id) {
        tokenA.mint(DEPOSIT_PAYER, FeeMath.gross(DEPOSIT_UNITS, SCALE, FEE_BPS));
        vm.prank(DEPOSIT_PAYER);
        tokenA.approve(permit2, type(uint256).max);

        PubInputs.DepositRequest memory d =
            DepositFixture.request(ASSET_A, DEPOSIT_UNITS, DEPOSIT_PAYER, RECIPIENT, DEPOSIT_CM);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        id = masp.deposit(d, DepositFixture.sig(0), aux[0], aux[1]);
    }

    /// Flushes the deposit `_escrowDeposit` made.
    function _flushCall(uint256 id, bytes32 oldRoot, bytes32 newRoot, uint64 start)
        internal
        view
        returns (Bundler.Call memory)
    {
        PubInputs.TreeUpdateBatch memory tpi = DepositFixture.batch(oldRoot, newRoot, start, 1);
        DepositFixture.setDepositLeaves(tpi, 0, DEPOSIT_CM, ASSET_A, DEPOSIT_UNITS);
        MASP.DepositMeta[] memory meta = DepositFixture.metas(1, DEPOSIT_PAYER, uint32(block.number), FEE_BPS);

        return Bundler.Call({
            target: address(masp),
            data: abi.encodeCall(MASP.flushBatch, (DepositFixture.ids(id), meta, FixtureLoader.emptyProof(), tpi))
        });
    }
}
