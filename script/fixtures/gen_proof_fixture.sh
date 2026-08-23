#!/usr/bin/env bash
#
# Regenerates a real-Groth16-proof fixture: one proof per vector in a published
# witness vector from @lelantos-org/circuits.
#
#   script/fixtures/gen_proof_fixture.sh tree_update_batch
#   script/fixtures/gen_proof_fixture.sh transact_3x3
#
# Artifacts must come from the GitHub release, not from a local
# `circuits/build/`:
#
#   1. `just setup-*` contributes with `openssl rand -hex 32`, so a local
#      ceremony yields a different `delta` than the release. Proofs made against
#      a local zkey cannot satisfy the verifiers in src/verifiers/, which are
#      copied from the release.
#   2. A local `build/` may be partially rebuilt: a current r1cs/wasm beside a
#      zkey from an earlier ceremony.
#
# Fetch them first (they are not in the npm tarball):
#
#   gh release download v0.10.0 --repo lelantos-org/circuits -D <dir> \
#     -p '*_final.zkey' -p '*.wasm' -p '*verification_key.json'
#
# then point RELEASE at <dir> and CIRCUITS at a circuits checkout (for the
# vectors and the snarkjs binary):
#
#   RELEASE=/path/to/rel092 CIRCUITS=../circuits \
#     script/fixtures/gen_proof_fixture.sh tree_update_batch
#
# Groth16 proving is randomized, so a refresh produces a different but equally
# valid proof triple over identical public signals. Each proof's public signals
# are asserted against the vector's (y, z) before writing, and the release
# verification key is asserted against the corresponding Solidity verifier, so a
# mismatched artifact set fails here rather than during a test run.
set -euo pipefail

CIRCUIT="${1:-}"
case "$CIRCUIT" in
    tree_update_batch)
        VECTOR_NAME="tree-update-batch-4.json"
        ZKEY_NAME="tree_update_batch_final.zkey"
        WASM_NAME="tree_update_batch.wasm"
        VKEY_NAME="tree_update_batch_verification_key.json"
        VERIFIER_SOL="src/verifiers/TreeUpdateBatchVerifier.sol"
        OUT_NAME="tree_update_batch_proof.json"
        ;;
    transact_3x3)
        VECTOR_NAME="transact-3x3.json"
        ZKEY_NAME="3x3_final.zkey"
        WASM_NAME="3x3.wasm"
        VKEY_NAME="3x3_verification_key.json"
        VERIFIER_SOL="src/verifiers/Verifier.sol"
        OUT_NAME="transact_3x3_proof.json"
        ;;
    *)
        echo "usage: $0 {tree_update_batch|transact_3x3}" >&2
        exit 2
        ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CIRCUITS="$(cd "${CIRCUITS:-$HERE/../circuits}" && pwd)"
RELEASE="$(cd "${RELEASE:?set RELEASE to a directory of v0.10.0 release assets}" && pwd)"

VECTOR="$CIRCUITS/vectors/$VECTOR_NAME"
SNARKJS="$CIRCUITS/node_modules/.bin/snarkjs"
ZKEY="$RELEASE/$ZKEY_NAME"
WASM="$RELEASE/$WASM_NAME"
VKEY="$RELEASE/$VKEY_NAME"
OUT="$HERE/test/fixtures/$OUT_NAME"

for f in "$VECTOR" "$ZKEY" "$WASM" "$VKEY" "$SNARKJS" "$HERE/$VERIFIER_SOL"; do
    [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

# The release verification key must match the one the Solidity verifier encodes.
python3 - "$VKEY" "$HERE/$VERIFIER_SOL" <<'PY'
import json, re, sys

vk = json.load(open(sys.argv[1]))
sol = open(sys.argv[2]).read()
const = {m[1]: int(m[2]) for m in re.finditer(r'uint256\s+constant\s+(\w+)\s*=\s*(\d+);', sol)}

# snarkjs codegen ordering: G2 coordinates are emitted (x1, x0), (y1, y0).
d = vk['vk_delta_2']
expect = {
    'deltax1': int(d[0][1]), 'deltax2': int(d[0][0]),
    'deltay1': int(d[1][1]), 'deltay2': int(d[1][0]),
}
for i, ic in enumerate(vk['IC']):
    expect[f'IC{i}x'], expect[f'IC{i}y'] = int(ic[0]), int(ic[1])

for k, v in expect.items():
    got = const.get(k)
    assert got == v, f'{sys.argv[2]}: {k} is {got}, release vkey says {v}'
print(f'verification key matches {sys.argv[2]}')
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

COUNT="$(python3 -c "import json;print(len(json.load(open('$VECTOR'))['vectors']))")"

for ((i = 0; i < COUNT; i++)); do
    python3 -c "
import json
d = json.load(open('$VECTOR'))
json.dump(d['vectors'][$i]['witness'], open('$TMP/in_$i.json', 'w'))
"
    # The release ships the bare .wasm without the generated CommonJS witness
    # builder, so use snarkjs rather than generate_witness.js.
    node "$SNARKJS" wtns calculate "$WASM" "$TMP/in_$i.json" "$TMP/w_$i.wtns"
    node "$SNARKJS" groth16 prove "$ZKEY" "$TMP/w_$i.wtns" "$TMP/proof_$i.json" "$TMP/public_$i.json"
    node "$SNARKJS" groth16 verify "$VKEY" "$TMP/public_$i.json" "$TMP/proof_$i.json"
    node "$SNARKJS" zkey export soliditycalldata "$TMP/public_$i.json" "$TMP/proof_$i.json" \
        > "$TMP/calldata_$i.txt"
done

python3 - "$VECTOR" "$VECTOR_NAME" "$TMP" "$COUNT" "$OUT" <<'PY'
import json, re, sys

vector_path, vector_name, tmp, count, out_path = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
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
        'vector': vector_name,
        'generator': vector['circuit']['id'],
        'template': vector['circuit']['template'],
        'layoutDigest': vector['circuit']['layoutDigest'],
    },
    'proofs': entries,
}, open(out_path, 'w'), indent=2)
print(f'wrote {out_path}: {len(entries)} proofs')
PY
