// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Groth16 verifying-key constants for the two circuits a spend proves, lifted
// verbatim from the snarkjs codegen verifiers so that `BatchedGroth16Verifier`
// has a single source of truth for them.
//
// Circuit 1 is `4x6` (`Verifier.sol`), circuit 2 is
// `tree_update_batch` (`TreeUpdateBatchVerifier.sol`).
//
// `Verifier.sol` is not deployed. It is the provenance of the `VK1_*` constants
// below and the oracle in `test/BatchedGroth16Verifier.t.sol`.
//
// `alpha`, `beta` and `gamma` are shared: both circuits were set up against the
// same `powersOfTau28_hez_final_16.ptau`, so alpha and beta are the same
// ptau-derived points, and snarkjs always fixes gamma to the G2 generator. Only
// `delta` and the `IC` points are per-circuit. That sharing lets the batched
// verifier fold the two `e(alpha, beta)` terms into one and the two
// `e(PI_i, gamma)` terms into one: six pairings instead of eight.
//
// These are declared at file level, not as library members, because inline
// assembly can reference a file-level or contract-level `constant` of value type
// by bare identifier but cannot reference `Lib.CONST`.
//
// If either circuit is ever rebuilt against a different ptau the shared values
// diverge and the batched verifier stops accepting anything (fail-closed).
// Regenerate this file and re-prove every fixture whenever a circuit changes.

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

uint256 constant VK1_DELTA_X1 = 4281478583458579390145935438494850524767702705271566739622390397193121004544;
uint256 constant VK1_DELTA_X2 = 7540625540230353084681827774032799376827691994163171295524958364724761907090;
uint256 constant VK1_DELTA_Y1 = 10477010265559341184184106111648865167164114485814291590887118623972830434601;
uint256 constant VK1_DELTA_Y2 = 18941279290738818775920743241082078526841366431172820505882624123299821850350;

uint256 constant VK1_IC0X = 9169170650978410639230707810662368329717931510998670180935790725780391267831;
uint256 constant VK1_IC0Y = 12723670661993347861739882210244277209242093008417887027929121505545727066882;
uint256 constant VK1_IC1X = 11838610451858780141631500123631033453277103793415917401852943385177336362391;
uint256 constant VK1_IC1Y = 18212168858482934167169167596211539853909869768625498877302082148470909565814;
uint256 constant VK1_IC2X = 1104484580235059774257190252798493862643431181614724128856917919585021405395;
uint256 constant VK1_IC2Y = 11747161231248698306432681111347353122385280461926944996889757527581282155473;

// ---------------------------------------------------------------------------
// Circuit 2 — tree_update_batch, MAX_L = 4 (src/verifiers/TreeUpdateBatchVerifier.sol)
// ---------------------------------------------------------------------------

uint256 constant VK2_DELTA_X1 = 11350293034882680347011663573987034552059666750016967596718122869115168833323;
uint256 constant VK2_DELTA_X2 = 10191882752144756021885781297671399799001749560231642350718963936142900284954;
uint256 constant VK2_DELTA_Y1 = 20445943432290821072052331200537561230111864483223470842057793008858922453633;
uint256 constant VK2_DELTA_Y2 = 7827464290565774413034508363603171972461130730782929521832907841107315411245;

uint256 constant VK2_IC0X = 20814529333030147239381789517487049109391479707977478916267817530517982563695;
uint256 constant VK2_IC0Y = 9781026126637097843175409160127414763275396745309930271302551263668902043796;
uint256 constant VK2_IC1X = 8471579352839907510223622813238416548169737989075791876024067466054708681361;
uint256 constant VK2_IC1Y = 17741464336380702509342876959023625426091941611520615624799773126101459593425;
uint256 constant VK2_IC2X = 1041603993604601856930742505015935422439633013054988813806561805517096244762;
uint256 constant VK2_IC2Y = 20265114777933967980249368131728487713164467470006795102187886585710768896200;

// ---------------------------------------------------------------------------
// Domain separator
// ---------------------------------------------------------------------------

// Prefix for the Fiat-Shamir transcript that derives the batching coefficient.
//
// Equal to `keccak256(abi.encode(...))` over all thirty verifying-key constants
// above, in exactly this order:
//
//   VK_ALPHA_X, VK_ALPHA_Y,
//   VK_BETA_X1, VK_BETA_X2, VK_BETA_Y1, VK_BETA_Y2,
//   VK_GAMMA_X1, VK_GAMMA_X2, VK_GAMMA_Y1, VK_GAMMA_Y2,
//   VK1_DELTA_X1, VK1_DELTA_X2, VK1_DELTA_Y1, VK1_DELTA_Y2,
//   VK1_IC0X, VK1_IC0Y, VK1_IC1X, VK1_IC1Y, VK1_IC2X, VK1_IC2Y,
//   VK2_DELTA_X1, VK2_DELTA_X2, VK2_DELTA_Y1, VK2_DELTA_Y2,
//   VK2_IC0X, VK2_IC0Y, VK2_IC1X, VK2_IC1Y, VK2_IC2X, VK2_IC2Y
//
// It is a literal rather than a computed expression because Solidity cannot
// fold `keccak256(abi.encode(...))` into a compile-time `constant`. A test must
// recompute it, so that editing any key constant without regenerating this
// value fails loudly instead of silently reusing a stale domain.
//
// This is defence in depth: the keys are fixed in bytecode, so a deployment
// with different keys is a different contract regardless. It costs ~40 gas and
// keeps any future instantiation from sharing a challenge derivation.
bytes32 constant BATCH_DOMAIN = 0x0d5247d7bacdbee5f5e6b36a2b71f391b983be4b51688fd9ce9e138d15ef4be1;
