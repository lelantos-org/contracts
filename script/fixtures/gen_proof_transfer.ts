// Transfer-scenario fixture: bootstrap tree to 2 spendable notes, then
// spend them via transact_2x2 + tree_update_batch (N=1).
//
// Output proof_transfer.json has two chained sub-fixtures:
//   bootstrap — seeds indices 0,1 over empty tree (submitIntent + flushBatch).
//   transfer  — spends them, inserts new outputs at indices 2,3.
//
// All notes value=0, rcv=rcv_dep=0 → cv = cv_dep = BJJ identity (0,1).
// Per-pair aggregate trivial: identity + identity = 0·V + 0·H = identity.

import { dirname, resolve } from "path";
import { fileURLToPath } from "url";
// @ts-ignore — snarkjs has no published TS types
import { groth16 } from "snarkjs";

import { existsSync } from "fs";

import {
    BJJ_IDENTITY,
    DEPTH,
    Jubjub,
    MerkleTree,
    Poseidon,
    type Field,
    type Groth16Output,
    batchInputJson,
    buildPaddedFields,
    buildNoteCommitment,
    derivePk,
    deriveIvk,
    deriveNk,
    fiatShamirZ,
    flatten,
    flattenTreeUpdateBatch,
    fmdFlag,
    fmdFlagKeyFromDetection,
    fmdGenDetectionKey,
    hornerEval,
    leafHash,
    packProof,
    requireCircuitsBuild,
    runMain,
    toCircomInput,
    toSpentNoteFromPath,
    writeJsonFixture,
} from "./_shared.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

const ASSET = 1n;
const CHAIN_ID = 31337n;
const RECIPIENT_ADDR = 0xb0bn;
const PAYER_ADDR = 0xfacen;
const RELAYER_ADDR = 0xcafen;
const ALICE_NSK = 11n;
const FMD_GAMMA = 5;

// TX_CIRCUITS_BUILD: path to the 2x2 circuit build dir (zkey + wasm).
// TUB_CIRCUITS_BUILD: path to the tree_update_batch circuit build dir.
// Both default to CIRCUITS_BUILD. The npm @lelantos-org/circuits package puts
// wasm at the root of build/ (not in <circuit>_js/); detect both layouts.
const CIRCUITS_BUILD = requireCircuitsBuild();
const TX_CIRCUITS_BUILD = process.env.TX_CIRCUITS_BUILD ?? CIRCUITS_BUILD;
const TUB_CIRCUITS_BUILD = process.env.TUB_CIRCUITS_BUILD ?? CIRCUITS_BUILD;
const _txWasmSubdir = resolve(TX_CIRCUITS_BUILD, "2x2_js", "2x2.wasm");
const _txWasmRoot = resolve(TX_CIRCUITS_BUILD, "2x2.wasm");
const TX_WASM = existsSync(_txWasmSubdir) ? _txWasmSubdir : _txWasmRoot;
const TX_ZKEY = resolve(TX_CIRCUITS_BUILD, "2x2_final.zkey");
const _tubWasmSubdir = resolve(TUB_CIRCUITS_BUILD, "tree_update_batch_js", "tree_update_batch.wasm");
const _tubWasmRoot = resolve(TUB_CIRCUITS_BUILD, "tree_update_batch.wasm");
const TUB_WASM = existsSync(_tubWasmSubdir) ? _tubWasmSubdir : _tubWasmRoot;
const TUB_ZKEY = resolve(TUB_CIRCUITS_BUILD, "tree_update_batch_final.zkey");

const DEFAULT_OUT = resolve(__dirname, "..", "..", "test", "fixtures", "proof_transfer.json");

// Build a single FMD clue from a deterministic seed. Returns the
// unpacked R, packed clue bits, and the flag-key X coord.
function buildClue(P: Poseidon, J: Jubjub, seed: bigint, fmdR: bigint) {
    let s = seed | 1n;
    const stream = (): bigint => {
        s = (s * 6364136223846793005n + 1442695040888963407n) & ((1n << 128n) - 1n);
        return s | 1n;
    };
    const dk = fmdGenDetectionKey(stream, FMD_GAMMA);
    const fk = fmdFlagKeyFromDetection(J, dk);
    const clue = fmdFlag(J, P, fk, fmdR);
    const Rpoint = J.unpackPoint(clue.R);
    if (!Rpoint) throw new Error("clue R unpack");
    let bits: bigint = 0n;
    for (let i = 0; i < FMD_GAMMA; i++) {
        const b = (clue.bits[i >> 3] >> (i & 7)) & 1;
        if (b) bits |= 1n << BigInt(i);
    }
    return { Rpoint, bits, r: fmdR, fk: fk.X };
}

async function main() {
    const P = await Poseidon.build();
    const J = await Jubjub.build();

    // Owner keys (single-owner test scenario; transfer is self → self).
    const ivk = deriveIvk(P, ALICE_NSK);
    const aliceP: Field = derivePk(P, ALICE_NSK);
    const nk = deriveNk(P, ALICE_NSK);
    void nk;
    void ivk;

    // ----- BOOTSTRAP STAGE: insert 2 real-preimage notes into empty tree. -----

    const tree = new MerkleTree(P, DEPTH);
    const bootstrapOldRoot = tree.root();
    const bootstrapFrontier = tree.frontier();

    // Two input notes (the spendable seed). Value=0, all blinders=0 → cv_dep
    // = BJJ identity; per-pair deposit aggregate is trivial.
    const inNote0 = {
        asset: ASSET, value: 0n, pk: aliceP, rho: 100n, rcm: 200n, rcv: 0n, rcvDep: 0n,
    };
    const inNote1 = {
        asset: ASSET, value: 0n, pk: aliceP, rho: 101n, rcm: 201n, rcv: 0n, rcvDep: 0n,
    };
    const inCm0 = buildNoteCommitment(P, inNote0);
    const inCm1 = buildNoteCommitment(P, inNote1);

    // Insert LEAF hashes (not raw cms) — circuit hashes leaf = Poseidon(
    // TAG_LEAF, cm, cv_dep_x, cv_dep_y) before inserting into the tree.
    const inLeaf0 = leafHash(P, inCm0, BJJ_IDENTITY);
    const inLeaf1 = leafHash(P, inCm1, BJJ_IDENTITY);
    tree.insert(inLeaf0);
    tree.insert(inLeaf1);
    const seedRoot = tree.root();

    const bootstrap = buildPaddedFields(
        [inCm0, inCm1],
        [BJJ_IDENTITY, BJJ_IDENTITY],
        [ASSET, ASSET],
        [0n, 0n],
        [1n, 1n],
        [0n, 0n],
    );

    const bootstrapCoeffs = flattenTreeUpdateBatch({
        oldRoot: bootstrapOldRoot,
        newRoot: seedRoot,
        startIndex: 0n,
        actualCount: 2n,
        cms: bootstrap.cms,
        cvDep: bootstrap.cvDep,
        leafAsset: bootstrap.leafAsset,
        leafPublicIn: bootstrap.leafPublicIn,
        isDeposit: bootstrap.isDeposit,
    });
    const bootstrapZ = fiatShamirZ(bootstrapCoeffs);
    const bootstrapY = hornerEval(bootstrapCoeffs, bootstrapZ);

    console.log("==> proving bootstrap tree_update_batch");
    const bootstrapResult = await groth16.fullProve(
        batchInputJson({
            oldRoot: bootstrapOldRoot,
            newRoot: seedRoot,
            startIndex: 0n,
            actualCount: 2n,
            cms: bootstrap.cms,
            cvDep: bootstrap.cvDep,
            leafAsset: bootstrap.leafAsset,
            leafPublicIn: bootstrap.leafPublicIn,
            isDeposit: bootstrap.isDeposit,
            rcv: bootstrap.rcv,
            frontier: bootstrapFrontier,
            z: bootstrapZ,
        }),
        TUB_WASM,
        TUB_ZKEY,
    );
    const bootstrapProof = bootstrapResult.proof as Groth16Output;
    {
        const sigs = bootstrapResult.publicSignals as string[];
        if (BigInt(sigs[1]) !== bootstrapZ) throw new Error("bootstrap z mismatch");
        if (BigInt(sigs[0]) !== bootstrapY) throw new Error("bootstrap y mismatch");
    }

    // ----- TRANSFER STAGE: spend in0+in1 over seedRoot; emit out0+out1 ------

    // Merkle proofs for the two input notes against the seed tree.
    const proof0 = tree.proof(0);
    const proof1 = tree.proof(1);
    const inSpent0 = toSpentNoteFromPath(
        P,
        { note: inNote0, nsk: ALICE_NSK, leafIndex: 0 },
        proof0.pathElements,
        proof0.pathIndices,
    );
    const inSpent1 = toSpentNoteFromPath(
        P,
        { note: inNote1, nsk: ALICE_NSK, leafIndex: 1 },
        proof1.pathElements,
        proof1.pathIndices,
    );

    // Frontier BEFORE inserting outputs — the relayer-frontier the transfer's
    // tree_update_batch consumes.
    const transferFrontier = tree.frontier();

    // Output notes (also self → self, zero-value).
    const outNote0 = {
        asset: ASSET, value: 0n, pk: aliceP, rho: 200n, rcm: 300n, rcv: 0n, rcvDep: 0n,
    };
    const outNote1 = {
        asset: ASSET, value: 0n, pk: aliceP, rho: 201n, rcm: 301n, rcv: 0n, rcvDep: 0n,
    };
    const outCm0 = buildNoteCommitment(P, outNote0);
    const outCm1 = buildNoteCommitment(P, outNote1);

    const outLeaf0 = leafHash(P, outCm0, BJJ_IDENTITY);
    const outLeaf1 = leafHash(P, outCm1, BJJ_IDENTITY);
    tree.insert(outLeaf0);
    tree.insert(outLeaf1);
    const transferNewRoot = tree.root();

    // FMD clues per output.
    const clue0 = buildClue(P, J, 0xa0n, 0x1234n);
    const clue1 = buildClue(P, J, 0xa1n, 0x5678n);

    // transact_2x2 input (no z yet — derive after flatten).
    const baseInput = toCircomInput(P, J, {
        publicAssetId: ASSET,
        publicIn: 0n,
        publicOut: 0n,
        inputs: [inSpent0, inSpent1],
        outputs: [outNote0, outNote1],
        outputClues: [
            { clueBits: clue0.bits, clueRx: clue0.Rpoint[0], clueRy: clue0.Rpoint[1] },
            { clueBits: clue1.bits, clueRx: clue1.Rpoint[0], clueRy: clue1.Rpoint[1] },
        ],
        merkleRoot: seedRoot,
        recipientAddress: RECIPIENT_ADDR,
        chainId: CHAIN_ID,
        payerAddress: PAYER_ADDR,
        relayerAddress: RELAYER_ADDR,
        z: 0n,
    });

    // Flatten + Fiat-Shamir z over the 30-coeff transact_2x2 PI vector
    // (24 base incl. 4 cv_dep coords + 6 clue PIs).
    const txCoeffs = flatten(baseInput as any);
    const txZ = fiatShamirZ(txCoeffs);
    const txY = hornerEval(txCoeffs, txZ);
    const txInput = { ...baseInput, z: txZ.toString() };

    console.log("==> proving transact_2x2");
    const txProveResult = await groth16.fullProve(txInput, TX_WASM, TX_ZKEY);
    const txProof = txProveResult.proof as Groth16Output;
    {
        const sigs = txProveResult.publicSignals as string[];
        if (BigInt(sigs[1]) !== txZ) throw new Error("transact z mismatch");
        if (BigInt(sigs[0]) !== txY) throw new Error("transact y mismatch");
    }

    // Transfer-leg tree_update_batch (2 output leaves, spend). is_deposit=0;
    // cvDeps[0..1] carry the transact_2x2's outCvDep so the on-chain
    // cross-bind passes.
    const transfer = buildPaddedFields(
        [outCm0, outCm1],
        [BJJ_IDENTITY, BJJ_IDENTITY],
        [0n, 0n],
        [0n, 0n],
        [0n, 0n],
        [0n, 0n],
    );
    const transferCoeffs = flattenTreeUpdateBatch({
        oldRoot: seedRoot,
        newRoot: transferNewRoot,
        startIndex: 2n,
        actualCount: 2n,
        cms: transfer.cms,
        cvDep: transfer.cvDep,
        leafAsset: transfer.leafAsset,
        leafPublicIn: transfer.leafPublicIn,
        isDeposit: transfer.isDeposit,
    });
    const transferZ = fiatShamirZ(transferCoeffs);
    const transferY = hornerEval(transferCoeffs, transferZ);

    console.log("==> proving transfer tree_update_batch");
    const transferTubResult = await groth16.fullProve(
        batchInputJson({
            oldRoot: seedRoot,
            newRoot: transferNewRoot,
            startIndex: 2n,
            actualCount: 2n,
            cms: transfer.cms,
            cvDep: transfer.cvDep,
            leafAsset: transfer.leafAsset,
            leafPublicIn: transfer.leafPublicIn,
            isDeposit: transfer.isDeposit,
            rcv: transfer.rcv,
            frontier: transferFrontier,
            z: transferZ,
        }),
        TUB_WASM,
        TUB_ZKEY,
    );
    const transferTubProof = transferTubResult.proof as Groth16Output;
    {
        const sigs = transferTubResult.publicSignals as string[];
        if (BigInt(sigs[1]) !== transferZ) throw new Error("transfer-tub z mismatch");
        if (BigInt(sigs[0]) !== transferY) throw new Error("transfer-tub y mismatch");
    }

    // Aux blobs for the spend transact_2x2.
    const auxFor = (c: { Rpoint: [bigint, bigint]; bits: bigint }) => {
        const bitsU16 = Number(c.bits);
        return {
            clueRx: c.Rpoint[0].toString(),
            clueRy: c.Rpoint[1].toString(),
            // On-curve, prime-order subgroup point (passes AuxValidation).
            // Identity (0, 1) is low-order and gets rejected.
            ephPubX: "5299619240641551281634865583518297030282874472190772894086521144482721001553",
            ephPubY: "16950150798460657717958625567821834550301663161624707787222815936182638968203",
            ciphertext:
                "0x" +
                ((bitsU16 >> 8) & 0xff).toString(16).padStart(2, "0") +
                (bitsU16 & 0xff).toString(16).padStart(2, "0"),
        };
    };

    const fixture = {
        chainId: CHAIN_ID.toString(),
        assetId: ASSET.toString(),
        recipient: "0x" + RECIPIENT_ADDR.toString(16).padStart(40, "0"),
        payer: "0x" + PAYER_ADDR.toString(16).padStart(40, "0"),
        relayer: "0x" + RELAYER_ADDR.toString(16).padStart(40, "0"),
        bootstrap: {
            oldRoot: bootstrapOldRoot.toString(),
            newRoot: seedRoot.toString(),
            startIndex: "0",
            actualCount: "2",
            cms: bootstrap.cms.map((c) => c.toString()),
            cvDeps: bootstrap.cvDep.map((pt) => [pt[0].toString(), pt[1].toString()]),
            leafAsset: bootstrap.leafAsset.map((v) => v.toString()),
            leafPublicIn: bootstrap.leafPublicIn.map((v) => v.toString()),
            isDeposit: bootstrap.isDeposit.map((v) => v.toString()),
            proof: packProof(bootstrapProof),
            publicSignals: [bootstrapY.toString(), bootstrapZ.toString()],
        },
        transfer: {
            merkleRoot: seedRoot.toString(),
            oldRoot: seedRoot.toString(),
            newRoot: transferNewRoot.toString(),
            startIndex: "2",
            actualCount: "2",
            cms: transfer.cms.map((c) => c.toString()),
            cvDeps: transfer.cvDep.map((pt) => [pt[0].toString(), pt[1].toString()]),
            leafAsset: transfer.leafAsset.map((v) => v.toString()),
            leafPublicIn: transfer.leafPublicIn.map((v) => v.toString()),
            isDeposit: transfer.isDeposit.map((v) => v.toString()),
            inCm0: inCm0.toString(),
            inCm1: inCm1.toString(),
            outCm0: outCm0.toString(),
            outCm1: outCm1.toString(),
            txProof: packProof(txProof),
            txPublicSignals: txCoeffs.map((c) => c.toString()),
            tubProof: packProof(transferTubProof),
            tubPublicSignals: [transferY.toString(), transferZ.toString()],
            aux: [auxFor(clue0), auxFor(clue1)],
        },
    };

    const out = resolve(process.env.PROOF_TRANSFER_OUT ?? DEFAULT_OUT);
    writeJsonFixture(out, fixture);
}

runMain(main);
