// Emit proof_deposit_batch.json fixture for tree_update_batch.circom.
// Mirrors relayer flush flow. N=1 deposit case (1 deposit, 2 leaves)
// over empty tree. Layout: see _shared.ts :: flattenTreeUpdateBatch.
//
// Zero-value zero-blinder notes → cv_dep collapses to BJJ identity (0,1).
// Per-pair aggregate holds trivially: identity + identity = 0·V + 0·H.

import { dirname, resolve } from "path";
import { fileURLToPath } from "url";
// @ts-ignore — snarkjs has no published TS types
import { groth16 } from "snarkjs";

import {
    BJJ_IDENTITY,
    DEPTH,
    MAX_N,
    MerkleTree,
    Poseidon,
    type Field,
    type Groth16Output,
    batchInputJson,
    fiatShamirZ,
    flattenTreeUpdateBatch,
    hornerEval,
    leafHash,
    packProof,
    requireCircuitsBuild,
    runMain,
    writeJsonFixture,
} from "./_shared.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

const ACTUAL_COUNT = 1;
const START_INDEX = 0;
const CM0 = 0xc0ffeen;
const CM1 = 0xfaceb00cn;

const CIRCUITS_BUILD = requireCircuitsBuild();
const TUB_WASM = resolve(CIRCUITS_BUILD, "tree_update_batch_js", "tree_update_batch.wasm");
const TUB_ZKEY = resolve(CIRCUITS_BUILD, "tree_update_batch_final.zkey");

const DEFAULT_OUT = resolve(__dirname, "..", "..", "test", "fixtures", "proof_deposit_batch_n1.json");

async function main() {
    const P = await Poseidon.build();

    // Active cv_dep: BJJ identity. Inactive slots zero (enforced below).
    const realCms: Field[] = [CM0, CM1];
    const activeCvDep: [Field, Field][] = [BJJ_IDENTITY, BJJ_IDENTITY];
    const leaves: Field[] = realCms.map((cm, j) => leafHash(P, cm, activeCvDep[j]));

    const tree = new MerkleTree(P, DEPTH);
    const oldRoot = tree.root();
    const oldFrontier = tree.frontier();
    for (const leaf of leaves) tree.insert(leaf);
    const newRoot = tree.root();

    // Pad to MAX_N. Inactive cv_dep MUST be (0,0).
    const cms: Field[] = new Array(2 * MAX_N).fill(0n);
    for (let i = 0; i < realCms.length; i++) cms[i] = realCms[i];
    const cvDep: [Field, Field][] = new Array(2 * MAX_N).fill(0).map(() => [0n, 0n] as [Field, Field]);
    for (let i = 0; i < 2 * ACTUAL_COUNT; i++) cvDep[i] = activeCvDep[i];

    const pairAsset: Field[] = new Array(MAX_N).fill(0n);
    const pairPublicIn: Field[] = new Array(MAX_N).fill(0n);
    const isDeposit: Field[] = new Array(MAX_N).fill(0n);
    const rcvTotal: Field[] = new Array(MAX_N).fill(0n);
    for (let i = 0; i < ACTUAL_COUNT; i++) isDeposit[i] = 1n;

    const args = {
        oldRoot,
        newRoot,
        startIndex: BigInt(START_INDEX),
        actualCount: BigInt(ACTUAL_COUNT),
        cms,
        cvDep,
        pairAsset,
        pairPublicIn,
        isDeposit,
    };
    const coeffs = flattenTreeUpdateBatch(args);
    const z = fiatShamirZ(coeffs);
    const y = hornerEval(coeffs, z);

    console.log("==> proving tree_update_batch (N=1 deposit)");
    const prove = await groth16.fullProve(
        batchInputJson({ ...args, frontier: oldFrontier, z, rcvTotal }),
        TUB_WASM,
        TUB_ZKEY,
    );
    const proof = prove.proof as Groth16Output;
    const signals = prove.publicSignals as string[];
    if (signals.length !== 2) throw new Error(`expected 2 signals, got ${signals.length}`);
    if (BigInt(signals[1]) !== z) throw new Error("z mismatch");
    if (BigInt(signals[0]) !== y) throw new Error("y mismatch");

    const out = resolve(process.env.PROOF_DEPOSIT_BATCH_OUT ?? DEFAULT_OUT);
    writeJsonFixture(out, {
        depth: DEPTH,
        maxN: MAX_N,
        actualCount: ACTUAL_COUNT,
        startIndex: START_INDEX,
        oldRoot: oldRoot.toString(),
        newRoot: newRoot.toString(),
        cms: cms.map((c) => c.toString()),
        cvDeps: cvDep.map((pt) => [pt[0].toString(), pt[1].toString()]),
        pairAsset: pairAsset.map((v) => v.toString()),
        pairPublicIn: pairPublicIn.map((v) => v.toString()),
        isDeposit: isDeposit.map((v) => v.toString()),
        proof: packProof(proof),
        publicSignals: signals, // [y, z] in solidity verifier convention
    });
}

runMain(main);
