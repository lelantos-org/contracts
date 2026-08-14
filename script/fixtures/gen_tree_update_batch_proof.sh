#!/usr/bin/env bash
#
# Regenerates test/fixtures/tree_update_batch_proof.json: one real Groth16 proof
# per vector in the published `tree-update-batch-8` witness vector.
#
# Needs a local circuits checkout with a built `build/` directory — the npm
# tarball ships only the 2x2 and 3x3 prover artifacts, so `tree_update_batch`
# proving keys have to come from a local `just build`. Point CIRCUITS at it:
#
#   CIRCUITS=../circuits script/fixtures/gen_tree_update_batch_proof.sh
#
# Groth16 proving is randomized, so re-running produces a different — equally
# valid — proof triple. The public signals are deterministic and are asserted
# against the vector's own (y, z) before anything is written.
set -euo pipefail

CIRCUITS="${CIRCUITS:-../circuits}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$HERE/test/fixtures/tree_update_batch_proof.json"

cd "$CIRCUITS"
CIRCUITS_ABS="$PWD"

VECTOR="$CIRCUITS_ABS/vectors/tree-update-batch-8.json"
ZKEY="$CIRCUITS_ABS/build/tree_update_batch_final.zkey"
WASM="$CIRCUITS_ABS/build/tree_update_batch_js/tree_update_batch.wasm"
VKEY="$CIRCUITS_ABS/build/tree_update_batch_verification_key.json"
SNARKJS="$CIRCUITS_ABS/node_modules/.bin/snarkjs"

for f in "$VECTOR" "$ZKEY" "$WASM" "$VKEY" "$SNARKJS"; do
    [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The circuits package is an ES module, so the generated CommonJS witness
# builder has to be run under a .cjs extension.
sed 's#\./witness_calculator\.js#./witness_calculator.cjs#' \
    "$CIRCUITS_ABS/build/tree_update_batch_js/generate_witness.js" > "$TMP/gw.cjs"
cp "$CIRCUITS_ABS/build/tree_update_batch_js/witness_calculator.js" "$TMP/witness_calculator.cjs"

COUNT="$(python3 -c "import json;print(len(json.load(open('$VECTOR'))['vectors']))")"

for ((i = 0; i < COUNT; i++)); do
    python3 -c "
import json
d = json.load(open('$VECTOR'))
json.dump(d['vectors'][$i]['witness'], open('$TMP/in_$i.json', 'w'))
"
    node "$TMP/gw.cjs" "$WASM" "$TMP/in_$i.json" "$TMP/w_$i.wtns"
    node "$SNARKJS" groth16 prove "$ZKEY" "$TMP/w_$i.wtns" "$TMP/proof_$i.json" "$TMP/public_$i.json"
    node "$SNARKJS" groth16 verify "$VKEY" "$TMP/public_$i.json" "$TMP/proof_$i.json"
    node "$SNARKJS" zkey export soliditycalldata "$TMP/public_$i.json" "$TMP/proof_$i.json" \
        > "$TMP/calldata_$i.txt"
done

python3 - "$VECTOR" "$TMP" "$COUNT" "$OUT" <<'PY'
import json, re, sys

vector_path, tmp, count, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
vector = json.load(open(vector_path))

entries = []
for i in range(count):
    words = re.findall(r'0x[0-9a-fA-F]{64}', open(f'{tmp}/calldata_{i}.txt').read())
    assert len(words) == 10, f'vector {i}: expected 10 calldata words, got {len(words)}'

    v = vector['vectors'][i]
    # snarkjs emits (y, z); the circuit's public signals are the output first,
    # then the public input. Pin both against the vector's own compression.
    y, z = int(words[8], 16), int(words[9], 16)
    assert y == int(v['compression']['y']), f'vector {i}: y mismatch'
    assert z == int(v['compression']['z']), f'vector {i}: z mismatch'

    entries.append({
        'name': v['name'],
        # G2 coordinates are already in the (x1, x0), (y1, y0) order the
        # precompile expects: taken from `zkey export soliditycalldata`, not
        # from proof.json, which stores them the other way round.
        'a': words[0:2],
        'b': [words[2:4], words[4:6]],
        'c': words[6:8],
        'pubSignals': words[8:10],
    })

json.dump({
    'schema': 'lelantos.contracts.proof-fixture/1',
    'source': {
        'vector': 'tree-update-batch-8.json',
        'generator': vector['circuit']['id'],
        'template': vector['circuit']['template'],
        'layoutDigest': vector['circuit']['layoutDigest'],
    },
    'proofs': entries,
}, open(out_path, 'w'), indent=2)
print(f'wrote {out_path}: {len(entries)} proofs')
PY
