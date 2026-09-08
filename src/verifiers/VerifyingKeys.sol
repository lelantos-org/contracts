// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Groth16 verifying-key constants for the two circuits a spend proves, lifted
// verbatim from the snarkjs codegen verifiers so `BatchedGroth16Verifier` has a
// single source of truth for them.
//
// Circuit 1 is `4x6` (`Verifier.sol`), circuit 2 is `tree_update_batch`
// (`TreeUpdateBatchVerifier.sol`). `Verifier.sol` is not deployed; it is the
// provenance of the `VK1_*` constants below and the oracle in
// `test/BatchedGroth16Verifier.t.sol`.
//
// `alpha`, `beta` and `gamma` are shared: both circuits were set up against the
// same `powersOfTau28_hez_final_16.ptau`, so alpha and beta are the same
// ptau-derived points, and snarkjs fixes gamma to the G2 generator. Only `delta`
// and the `IC` points are per-circuit. That sharing lets the batched verifier
// fold the two `e(alpha, beta)` terms into one and the two `e(PI_i, gamma)`
// terms into one: six pairings instead of eight.
//
// Declared at file level rather than as library members: inline assembly can
// reference a file-level or contract-level `constant` of value type by bare
// identifier but cannot reference `Lib.CONST`.
//
// Rebuilding either circuit against a different ptau diverges the shared values
// and the batched verifier stops accepting anything (fail-closed). Regenerate
// this file and re-prove every fixture whenever a circuit changes.

// ---------------------------------------------------------------------------
// Field moduli (identical in both codegen verifiers)
// ---------------------------------------------------------------------------

// BN254 scalar field order. Matches `Groth16Verifier.r` and `SnarkCompression.R`.
uint256 constant SNARK_R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

// BN254 base field order. Matches `Groth16Verifier.q`.
uint256 constant SNARK_Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

// ---------------------------------------------------------------------------
// Shared across both circuits
// ---------------------------------------------------------------------------

uint256 constant VK_ALPHA_X = 20491192805390485299153009773594534940189261866228447918068658471970481763042;
uint256 constant VK_ALPHA_Y = 9383485363053290200918347156157836566562967994039712273449902621266178545958;

uint256 constant VK_BETA_X1 = 4252822878758300859123897981450591353533073413197771768651442665752259397132;
uint256 constant VK_BETA_X2 = 6375614351688725206403948262868962793625744043794305715222011528459656738731;
uint256 constant VK_BETA_Y1 = 21847035105528745403288232691147584728191162732299865338377159692350059136679;
uint256 constant VK_BETA_Y2 = 10505242626370262277552901082094356697409835680220590971873171140371331206856;

// The BN254 G2 generator.
uint256 constant VK_GAMMA_X1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
uint256 constant VK_GAMMA_X2 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
uint256 constant VK_GAMMA_Y1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;
uint256 constant VK_GAMMA_Y2 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;

// ---------------------------------------------------------------------------
// Circuit 1 — 4x6 (src/verifiers/Verifier.sol)
// ---------------------------------------------------------------------------

uint256 constant VK1_DELTA_X1 = 15886902705877037961037230797170759371268494338457929667938520539714656560308;
uint256 constant VK1_DELTA_X2 = 1741840564810404857249863469820610154771001739656050449454291263753692814248;
uint256 constant VK1_DELTA_Y1 = 6693916459205785032874987060194236944064329595162751447960267865973028872703;
uint256 constant VK1_DELTA_Y2 = 7733115101040411116697301809617130188364479270072395536872978020157879341225;

uint256 constant VK1_IC0X = 9000079759558951107176795198911526252309875328582927078672158524201737527497;
uint256 constant VK1_IC0Y = 16699515151812402935373842389253930320231651425753059260188241154704734345081;
uint256 constant VK1_IC1X = 760535443569538096383015975828355841762125442690430701485963291121291904631;
uint256 constant VK1_IC1Y = 7932695176175249399956027105804835587653373982039484875570202314640982562619;
uint256 constant VK1_IC2X = 20647453367783461496338622955155213265058892179997963455075973482888307024431;
uint256 constant VK1_IC2Y = 4181312152269065102443332273825630254341908484380830381195062903153741278339;

// ---------------------------------------------------------------------------
// Circuit 2 — tree_update_batch, MAX_L = 8 (src/verifiers/TreeUpdateBatchVerifier.sol)
// ---------------------------------------------------------------------------

uint256 constant VK2_DELTA_X1 = 9724547219193624912737112056570819233427323692063466848516310928428776657324;
uint256 constant VK2_DELTA_X2 = 3895766906108975170973044305345165671918851157767581659581925511215970815894;
uint256 constant VK2_DELTA_Y1 = 662512044860863130736247642413634825430176986260149202373163438135201935933;
uint256 constant VK2_DELTA_Y2 = 10076212383835652575368183990192665464071362155000951001459437816192219418396;

uint256 constant VK2_IC0X = 11731288182797468532047501896187627816861524591529942854336297058343059313927;
uint256 constant VK2_IC0Y = 5304360266424458546412919336138933293204883887442242272408354915178211577441;
uint256 constant VK2_IC1X = 16628540803725861329478379774015207594772110766524343807186737729409853920503;
uint256 constant VK2_IC1Y = 21628617151705412532811372262602130566711779331969252515904218877697855172358;
uint256 constant VK2_IC2X = 2666893293132911006780409139780494823945412530704382333528325299131461021693;
uint256 constant VK2_IC2Y = 19475378098484158113229806727459863807085079694570223025908448222820326942556;

// ---------------------------------------------------------------------------
// Domain separator
// ---------------------------------------------------------------------------

// Prefix for the Fiat-Shamir transcript that derives the batching coefficient.
//
// Equal to `keccak256(abi.encode(...))` over all thirty verifying-key constants
// above, in this order:
//
//   VK_ALPHA_X, VK_ALPHA_Y,
//   VK_BETA_X1, VK_BETA_X2, VK_BETA_Y1, VK_BETA_Y2,
//   VK_GAMMA_X1, VK_GAMMA_X2, VK_GAMMA_Y1, VK_GAMMA_Y2,
//   VK1_DELTA_X1, VK1_DELTA_X2, VK1_DELTA_Y1, VK1_DELTA_Y2,
//   VK1_IC0X, VK1_IC0Y, VK1_IC1X, VK1_IC1Y, VK1_IC2X, VK1_IC2Y,
//   VK2_DELTA_X1, VK2_DELTA_X2, VK2_DELTA_Y1, VK2_DELTA_Y2,
//   VK2_IC0X, VK2_IC0Y, VK2_IC1X, VK2_IC1Y, VK2_IC2X, VK2_IC2Y
//
// A literal rather than a computed expression, because Solidity cannot fold
// `keccak256(abi.encode(...))` into a compile-time `constant`. A test recomputes
// it, so editing any key constant without regenerating this value fails loudly
// rather than reusing a stale domain.
//
// Defence in depth: the keys are fixed in bytecode, so a deployment with
// different keys is a different contract regardless. It costs ~40 gas and keeps
// any future instantiation from sharing a challenge derivation.
bytes32 constant BATCH_DOMAIN = 0x74c589b12facc4235ced817c2767bb8e2321cf044e018c8f4c5017ec8c68bab5;
