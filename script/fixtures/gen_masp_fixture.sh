#!/usr/bin/env bash
#
# Regenerates test/fixtures/masp_flow_proof.json: real Groth16 proofs for
# requests the pool accepts end to end — one deposit flushed from the empty
# tree, then a transfer and a withdraw each spending that deposit's note.
#
#   script/fixtures/gen_masp_fixture.sh
#   RELEASE=/path/to/release CIRCUITS=../circuits script/fixtures/gen_masp_fixture.sh
#
# gen_proof_fixture.sh proves the circuits' published vectors, which the pool
# refuses before any proof check (zero recipient, payer, relayer and chain id,
# and a stand-in aux digest). The witnesses here are built for the pool instead,
# by `scripts/gen-masp-fixture.ts` in the circuits checkout, from the same
# reference code that generates those vectors; this script only locates it.
#
# RELEASE is the directory holding the circuits release's `*_final.zkey`,
# `*_verification_key.json` and `.wasm` files for both circuits: the release
# whose verifiers are vendored under src/verifiers/ (see
# test/fixtures/README.md). Download them as gen_proof_fixture.sh describes. It
# defaults to the circuits checkout's `build/prototype-0.20.0`, an untracked
# local copy of the v0.20.0 release assets; where a directory has no wasm, the
# generator takes it from `build/<circuit>_js/`.
#
# The generator asserts, before writing, that each verification key matches the
# vendored Solidity verifier, that every proof verifies under snarkjs, and that
# its public signals equal the (y, digest, z) computed the way PubInputs.sol
# computes them. Proving is randomized, so a refresh rewrites the proof triples
# over identical public signals.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CIRCUITS="$(cd "${CIRCUITS:-$HERE/../circuits}" && pwd)"
RELEASE="$(cd "${RELEASE:-$CIRCUITS/build/prototype-0.20.0}" && pwd)"

GENERATOR="$CIRCUITS/scripts/gen-masp-fixture.ts"
for f in "$GENERATOR" "$CIRCUITS/node_modules/tsx"; do
    [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

# Run from the circuits checkout so `tsx` resolves from its node_modules.
cd "$CIRCUITS"
NODE_OPTIONS="--import tsx/esm" node "$GENERATOR" \
    --keys "$RELEASE" \
    --contracts "$HERE" \
    --out "$HERE/test/fixtures/masp_flow_proof.json"
