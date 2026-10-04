// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Vm.sol";

import { MASP } from "../../src/MASP.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { DepositFixture } from "./DepositFixture.sol";
import { FeeMath } from "./FeeMath.sol";
import { FixtureLoader } from "./FixtureLoader.sol";
import { SPEND_OUTPUTS, SpendFixture } from "./SpendFixture.sol";
import { Stubs } from "./Stubs.sol";

/// Reader and replay helpers for `test/fixtures/masp_flow_proof.json`: real
/// Groth16 proofs for requests the pool accepts end to end.
///
/// The fixture is one small history. A deposit of the fixture asset is flushed
/// from the empty tree (`.flush`), and its note is then spent either by a
/// transfer (`.transfer`) or by a withdraw (`.withdraw`). The two spends are
/// alternatives: each consumes the deposit's nullifier and extends the tree the
/// flush left, so a test replays one of them per pool.
///
/// Regenerate with `script/fixtures/gen_masp_fixture.sh`; see
/// `test/fixtures/README.md`.
library MaspFlowFixture {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant PATH = "test/fixtures/masp_flow_proof.json";

    /// `flushBatch` arguments for the fixture's one deposit.
    struct Flush {
        PubInputs.TreeUpdateBatch tpi;
        MASP.Proof proof;
    }

    /// `transfer` / `withdraw` arguments, in call order.
    struct Spend {
        MASP.Proof txProof;
        PubInputs.Transact pi;
        MASP.Proof tubProof;
        PubInputs.SpendTree tpi;
        AuxValidation.Output[SPEND_OUTPUTS] aux;
    }

    function read() internal view returns (string memory) {
        return VM.readFile(PATH);
    }

    /// The chain the spends were proven for: `Transact.chainId` is hashed into
    /// the challenge, and the pool requires it to equal `block.chainid`.
    function chainId(string memory j) internal pure returns (uint256) {
        return VM.parseJsonUint(j, ".chainId");
    }

    function flush(string memory j) internal pure returns (Flush memory f) {
        f.tpi.oldRoot = bytes32(VM.parseJsonUint(j, ".flush.tpi.oldRoot"));
        f.tpi.newRoot = bytes32(VM.parseJsonUint(j, ".flush.tpi.newRoot"));
        f.tpi.startIndex = uint64(VM.parseJsonUint(j, ".flush.tpi.startIndex"));
        f.tpi.actualCount = uint64(VM.parseJsonUint(j, ".flush.tpi.actualCount"));
        for (uint256 k; k < PubInputs.MAX_L_BATCH; ++k) {
            string memory idx = string.concat("[", VM.toString(k), "]");
            // On a deposit slot this is the depositor's `inner`, not the leaf.
            f.tpi.cms[k] = bytes32(VM.parseJsonUint(j, string.concat(".flush.tpi.cms", idx)));
            f.tpi.leafAsset[k] = uint64(VM.parseJsonUint(j, string.concat(".flush.tpi.leafAsset", idx)));
            f.tpi.leafPublicIn[k] = uint64(VM.parseJsonUint(j, string.concat(".flush.tpi.leafPublicIn", idx)));
            f.tpi.isDeposit[k] = uint8(VM.parseJsonUint(j, string.concat(".flush.tpi.isDeposit", idx)));
        }
        // The batch circuit's commitment to the 36 words above.
        f.tpi.digest = VM.parseJsonUint(j, ".flush.tpi.digest");
        f.proof = FixtureLoader.readProof(j, ".flush.proof");
    }

    /// The spend at `key`, `".transfer"` or `".withdraw"`. `tpi.anchorIndex` is
    /// left zero: it is a lookup hint into the pool's root ring, not a proven
    /// word, so the caller sets it from the pool it replays against.
    function spend(string memory j, string memory key) internal pure returns (Spend memory s) {
        string memory pi = string.concat(key, ".pi");
        s.pi.merkleRoot = bytes32(VM.parseJsonUint(j, string.concat(pi, ".merkleRoot")));
        for (uint256 k; k < PubInputs.TRANSACT_IN; ++k) {
            s.pi.nullifier[k] = bytes32(VM.parseJsonUint(j, string.concat(pi, ".nullifier[", VM.toString(k), "]")));
        }
        for (uint256 k; k < PubInputs.TRANSACT_OUT; ++k) {
            string memory idx = string.concat("[", VM.toString(k), "]");
            s.pi.outCm[k] = bytes32(VM.parseJsonUint(j, string.concat(pi, ".outCm", idx)));

            string memory a = string.concat(key, ".aux", idx);
            s.aux[k].clueRx = VM.parseJsonUint(j, string.concat(a, ".clueRx"));
            s.aux[k].clueRy = VM.parseJsonUint(j, string.concat(a, ".clueRy"));
            s.aux[k].ephPubX = VM.parseJsonUint(j, string.concat(a, ".ephPubX"));
            s.aux[k].ephPubY = VM.parseJsonUint(j, string.concat(a, ".ephPubY"));
            s.aux[k].ciphertext = VM.parseJsonBytes(j, string.concat(a, ".ciphertext"));
        }
        s.pi.publicAssetId = uint64(VM.parseJsonUint(j, string.concat(pi, ".publicAssetId")));
        s.pi.publicOut = uint64(VM.parseJsonUint(j, string.concat(pi, ".publicOut")));
        // The transact circuit's commitment to the thirteen coefficients above:
        // the prover's copy, which the pool hashes and forwards.
        s.pi.digest = VM.parseJsonUint(j, string.concat(pi, ".digest"));
        s.pi.recipient = VM.parseJsonAddress(j, string.concat(pi, ".recipient"));
        s.pi.chainId = VM.parseJsonUint(j, string.concat(pi, ".chainId"));
        s.pi.payer = VM.parseJsonAddress(j, string.concat(pi, ".payer"));
        s.pi.relayer = VM.parseJsonAddress(j, string.concat(pi, ".relayer"));
        s.pi.intentHash = VM.parseJsonUint(j, string.concat(pi, ".intentHash"));

        // The pool rebuilds the rest of the batch image from `pi`; the digest is
        // the batch circuit's commitment to that image.
        s.tpi.newRoot = bytes32(VM.parseJsonUint(j, string.concat(key, ".tpi.newRoot")));
        s.tpi.startIndex = uint64(VM.parseJsonUint(j, string.concat(key, ".tpi.startIndex")));
        s.tpi.digest = VM.parseJsonUint(j, string.concat(key, ".tpi.digest"));

        s.txProof = FixtureLoader.readProof(j, string.concat(key, ".txProof"));
        s.tubProof = FixtureLoader.readProof(j, string.concat(key, ".tubProof"));
    }

    /// The deposit the flush proves, read back out of its batch slots: slot 0
    /// is the principal and slot 1 the relayer's fee note, which is what
    /// `MASP._drainDeposit` requires them to be.
    function depositRequest(Flush memory f, address payer, address recipient)
        internal
        view
        returns (PubInputs.DepositRequest memory d)
    {
        d = DepositFixture.request(f.tpi.leafAsset[0], f.tpi.leafPublicIn[0], payer, recipient, f.tpi.cms[0]);
        d.feeAssetId = f.tpi.leafAsset[1];
        d.feeIn = f.tpi.leafPublicIn[1];
        d.feeInner = f.tpi.cms[1];
    }

    /// Escrows the fixture's deposit through `MASP.deposit`: funds `payer`,
    /// gives it the permissive ERC-1271 stub Permit2 needs, and submits. The
    /// fee note carries no value, so the pull is the principal plus the
    /// treasury's fee at `fbps`, the pool's deposit rate for the asset.
    function escrow(
        MASP masp,
        MockERC20 token,
        Flush memory f,
        address payer,
        address recipient,
        uint256 scale,
        uint16 fbps
    ) internal returns (uint256 id) {
        Stubs.installPermissiveERC1271(payer);
        token.mint(payer, FeeMath.gross(f.tpi.leafPublicIn[0], scale, fbps));
        // Read before the prank, which the next call of any kind consumes.
        address permit2 = address(masp.PERMIT2());
        VM.prank(payer);
        token.approve(permit2, type(uint256).max);

        AuxValidation.Output memory aux = SpendFixture.validAuxOutput();
        id = masp.deposit(depositRequest(f, payer, recipient), DepositFixture.sig(0), aux, aux);
    }

    /// Flushes escrow `id`, submitted in this block, under the fixture's batch
    /// proof.
    function flushEscrow(MASP masp, Flush memory f, uint256 id, address payer, uint16 fbps) internal {
        masp.flushBatch(
            DepositFixture.ids(id), DepositFixture.metas(1, payer, uint32(block.number), fbps), f.proof, f.tpi
        );
    }

    /// Brings a fresh pool to the tree state both spends were proven against,
    /// through the pool's own entry points: `deposit`, then `flushBatch` with
    /// the real batch proof.
    function seedTree(
        MASP masp,
        MockERC20 token,
        Flush memory f,
        address payer,
        address recipient,
        uint256 scale,
        uint16 fbps
    ) internal {
        flushEscrow(masp, f, escrow(masp, token, f, payer, recipient, scale, fbps), payer, fbps);
    }
}
