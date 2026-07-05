// Shared helpers for proof_*.json fixture generators. Centralizes SDK
// path resolution + crypto/witness re-exports so a path change (e.g.
// sdk/src -> sdk/dist when the SDK ships built dist) hits one file.
//
// Layout invariants (DO NOT drift from circuit + PubInputs.sol):
//   MAX_N        — tree_update_batch.circom :: MAX_N (76 = 4 + 9*MAX_N coeffs)
//   DEPTH        — CommitmentTree depth (quaternary, depth 10)
//   BJJ_IDENTITY — Baby-Jubjub identity in twisted Edwards (cv_dep for value=0)
//   leaf hash    — Poseidon(TAG_LEAF, cm, cv_dep_x, cv_dep_y)

import { writeFileSync, mkdirSync } from "fs";
import { dirname, resolve } from "path";

// SDK re-exports via installed package subpaths.
export {
    Poseidon,
    Jubjub,
    MerkleTree,
    derivePk,
    deriveIvk,
    deriveNk,
    buildNoteCommitment,
    TAG_LEAF,
    TAG_MERKLE,
    type Field,
} from "@lelantos-org/sdk/crypto";
export { toCircomInput, toSpentNoteFromPath } from "@lelantos-org/sdk/witness";
export { fmdGenDetectionKey, fmdFlagKeyFromDetection, fmdFlag } from "@lelantos-org/sdk/fmd";
export { flatten, fiatShamirZ, hornerEval } from "@lelantos-org/sdk/bundle";

import type { Field } from "@lelantos-org/sdk/crypto";
import type { Poseidon } from "@lelantos-org/sdk/crypto";
import { TAG_LEAF } from "@lelantos-org/sdk/crypto";

export const DEPTH = 10;
export const MAX_N = 8;
export const BJJ_IDENTITY: [Field, Field] = [0n, 1n];

// snarkjs has no published TS types.
export interface Groth16Output {
    pi_a: string[];
    pi_b: string[][];
    pi_c: string[];
}

// Pack snarkjs proof into Solidity Groth16 verifier layout. G2 coords are
// swapped (imag-first) per EIP-197 / snarkjs exporter convention.
export function packProof(p: Groth16Output) {
    return {
        a: [p.pi_a[0], p.pi_a[1]],
        b: [
            [p.pi_b[0][1], p.pi_b[0][0]],
            [p.pi_b[1][1], p.pi_b[1][0]],
        ],
        c: [p.pi_c[0], p.pi_c[1]],
    };
}

export interface BatchArgs {
    oldRoot: Field;
    newRoot: Field;
    startIndex: bigint;
    actualCount: bigint;
    cms: Field[]; // 2*MAX_N
    cvDep: [Field, Field][]; // 2*MAX_N
    pairAsset: Field[]; // MAX_N
    pairPublicIn: Field[]; // MAX_N
    isDeposit: Field[]; // MAX_N
}

// Coefficient order MUST match tree_update_batch.circom :: PolyEval and
// PubInputs.sol :: compress(TreeUpdateBatch). Total = 4 + 9*MAX_N.
export function flattenTreeUpdateBatch(a: BatchArgs): Field[] {
    if (a.cms.length !== 2 * MAX_N) throw new Error(`cms len ${2 * MAX_N}`);
    if (a.cvDep.length !== 2 * MAX_N) throw new Error(`cvDep len ${2 * MAX_N}`);
    if (a.pairAsset.length !== MAX_N) throw new Error(`pairAsset len ${MAX_N}`);
    if (a.pairPublicIn.length !== MAX_N) throw new Error(`pairPublicIn len ${MAX_N}`);
    if (a.isDeposit.length !== MAX_N) throw new Error(`isDeposit len ${MAX_N}`);
    const out: Field[] = [a.oldRoot, a.newRoot, a.startIndex, a.actualCount];
    for (const c of a.cms) out.push(c);
    for (const pt of a.cvDep) {
        out.push(pt[0]);
        out.push(pt[1]);
    }
    for (const v of a.pairAsset) out.push(v);
    for (const v of a.pairPublicIn) out.push(v);
    for (const v of a.isDeposit) out.push(v);
    return out;
}

// Pad real prefix arrays to MAX_N. Inactive cv_dep slots MUST be zero
// (not identity) — circuit enforces.
export function buildPaddedFields(
    realCms: Field[],
    activeCvDep: [Field, Field][], // 2*actual_count
    activePairAsset: bigint[], // actual_count
    activePairPublicIn: bigint[], // actual_count
    activeIsDeposit: bigint[], // actual_count
    activeRcvTotal: bigint[], // actual_count
) {
    const cms: Field[] = new Array(2 * MAX_N).fill(0n);
    for (let i = 0; i < realCms.length; i++) cms[i] = realCms[i];

    const cvDep: [Field, Field][] = new Array(2 * MAX_N).fill(0).map(() => [0n, 0n] as [Field, Field]);
    for (let i = 0; i < activeCvDep.length; i++) cvDep[i] = activeCvDep[i];

    const pairAsset: Field[] = new Array(MAX_N).fill(0n);
    const pairPublicIn: Field[] = new Array(MAX_N).fill(0n);
    const isDeposit: Field[] = new Array(MAX_N).fill(0n);
    const rcvTotal: Field[] = new Array(MAX_N).fill(0n);
    for (let i = 0; i < activePairAsset.length; i++) {
        pairAsset[i] = activePairAsset[i];
        pairPublicIn[i] = activePairPublicIn[i];
        isDeposit[i] = activeIsDeposit[i];
        rcvTotal[i] = activeRcvTotal[i];
    }
    return { cms, cvDep, pairAsset, pairPublicIn, isDeposit, rcvTotal };
}

// JSON input shape consumed by tree_update_batch.wasm.
export function batchInputJson(a: BatchArgs & { frontier: Field[][]; z: Field; rcvTotal: Field[] }) {
    return {
        z: a.z.toString(),
        old_root: a.oldRoot.toString(),
        new_root: a.newRoot.toString(),
        start_index: a.startIndex.toString(),
        actual_count: a.actualCount.toString(),
        cms: a.cms.map((c) => c.toString()),
        cv_dep: a.cvDep.map((pt) => [pt[0].toString(), pt[1].toString()]),
        pair_asset: a.pairAsset.map((v) => v.toString()),
        pair_public_in: a.pairPublicIn.map((v) => v.toString()),
        is_deposit: a.isDeposit.map((v) => v.toString()),
        frontier_in: a.frontier.map((lvl) => lvl.map((s) => s.toString())),
        rcv_total: a.rcvTotal.map((v) => v.toString()),
    };
}

// leaf = Poseidon(TAG_LEAF, cm, cv_dep_x, cv_dep_y). Mirrors in-circuit
// computation (tree_update_batch.circom + spent.circom).
export function leafHash(P: Poseidon, cm: Field, cvDep: [Field, Field]): Field {
    return P.hash([TAG_LEAF, cm, cvDep[0], cvDep[1]]);
}

export function requireCircuitsBuild(): string {
    const v = process.env.CIRCUITS_BUILD;
    if (!v) throw new Error("CIRCUITS_BUILD env var required (path to circuits/build directory)");
    return v;
}

export function writeJsonFixture(outPath: string, payload: unknown) {
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, JSON.stringify(payload, null, 2) + "\n");
    console.log(`wrote -> ${outPath}`);
}

export function runMain(fn: () => Promise<void>) {
    fn().then(() => process.exit(0)).catch((e) => {
        console.error(e);
        process.exit(1);
    });
}

export { resolve as resolvePath, dirname as dirnamePath };
