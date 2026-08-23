// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Groth16 verifying-key constants for the two circuits a spend proves, lifted
// verbatim from the snarkjs codegen verifiers so that `BatchedGroth16Verifier`
// has a single source of truth for them.
//
// Circuit 1 is `transact_3x3` (`Verifier.sol`), circuit 2 is
// `tree_update_batch` (`TreeUpdateBatchVerifier.sol`).
//
// `Verifier.sol` is not deployed. It is the provenance of the `VK1_*` constants
// below and the oracle in `test/BatchedGroth16Verifier.t.sol`.
//
// `alpha`, `beta` and `gamma` are **shared**: both circuits were set up against
// the same `powersOfTau28_hez_final_16.ptau`, so alpha and beta are the same
// ptau-derived points, and snarkjs always fixes gamma to the G2 generator. Only
// `delta` and the `IC` points are per-circuit. That sharing is what lets the
// batched verifier fold the two `e(alpha, beta)` terms into one and the two
// `e(PI_i, gamma)` terms into one — six pairings instead of eight.
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
// Circuit 1 — transact_3x3 (src/verifiers/Verifier.sol)
// ---------------------------------------------------------------------------

uint256 constant VK1_DELTA_X1 = 16534574939409347825634460907325673335788210308138296953654518376658431869032;
uint256 constant VK1_DELTA_X2 = 9530686656721455095406635917224596747176902955997340602621041577589338428228;
uint256 constant VK1_DELTA_Y1 = 3793982309443952844426577963713801504603220316861345100846589092482877505564;
uint256 constant VK1_DELTA_Y2 = 14569759012112072251749864726440513585475914760576274199181122288019018833694;

uint256 constant VK1_IC0X = 17209340469798782648695833396298339207395324156381821907913572412618387853590;
uint256 constant VK1_IC0Y = 15778091263828580481955959995834978141061617357662831874943530680578767825124;
uint256 constant VK1_IC1X = 7815310160654294153176529125257849691619944427261158193878934187308365747548;
uint256 constant VK1_IC1Y = 9545684349022258247924950504639048280048403715120339676059565626136063233173;
uint256 constant VK1_IC2X = 6730324194412138967132736926430839157269825572805944377180069619166998788500;
uint256 constant VK1_IC2Y = 3721110754392882221009148828568317834720462413982309105945619119246148390599;

// ---------------------------------------------------------------------------
// Circuit 2 — tree_update_batch, MAX_L = 4 (src/verifiers/TreeUpdateBatchVerifier.sol)
// ---------------------------------------------------------------------------

uint256 constant VK2_DELTA_X1 = 3735461190119919696238043648922673846710170405667497460296413584145671901211;
uint256 constant VK2_DELTA_X2 = 21018539639664153886736211592995412431161632331886872816263363513305953514185;
uint256 constant VK2_DELTA_Y1 = 6174237810656008449045204154139002158717228059090329882122461665664318222249;
uint256 constant VK2_DELTA_Y2 = 9559190982952876807664136235632026122002221217271863323564692085036499100837;

uint256 constant VK2_IC0X = 19048363989986964359846938939263940893450656098062586997089018168089066870748;
uint256 constant VK2_IC0Y = 16639540765271333573304939721894169306609345070956592706872628759038674286041;
uint256 constant VK2_IC1X = 12386332801404593432116003466327250559893679424084312664078677825578502468716;
uint256 constant VK2_IC1Y = 3107424590400772069473905488782907385134580167166082226478764138684949218630;
uint256 constant VK2_IC2X = 16066428033717224057546695304859609995722693972256392333650951741347664034989;
uint256 constant VK2_IC2Y = 12182727389124042760827602941047145357903899550329448587875848720287668406312;

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
bytes32 constant BATCH_DOMAIN = 0xa0f2a09e61bd09951f4c73fb4137945401024b795fbf665cb7ce7fb8188d0752;
