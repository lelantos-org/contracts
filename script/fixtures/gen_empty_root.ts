// Genesis empty-tree root (depth-10 quaternary Merkle). Mirrors the
// constructor loop replaced by a hardcoded constant in CommitmentTree.
// Run: `npm run --silent gen-empty-root`.

import { dirname, resolve } from "path";
import { fileURLToPath } from "url";
import { DEPTH, Poseidon, TAG_MERKLE, runMain, writeJsonFixture } from "./_shared.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

runMain(async () => {
    const P = await Poseidon.build();
    let z = 0n;
    for (let i = 0; i < DEPTH; i++) {
        z = P.hash([TAG_MERKLE, z, z, z, z]);
    }
    const hex = "0x" + z.toString(16).padStart(64, "0");
    const out = resolve(__dirname, "../../test/fixtures/empty_root.json");
    writeJsonFixture(out, { depth: DEPTH, tag: Number(TAG_MERKLE), root: hex });
    console.log(hex);
});
