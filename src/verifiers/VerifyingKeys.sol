// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Groth16 verifying-key constants for the two circuits a spend proves, lifted
// verbatim from the snarkjs codegen verifiers so that `BatchedGroth16Verifier`
// has a single source of truth for them.
//
// Circuit 1 is `transact_4x4` (`Verifier.sol`), circuit 2 is
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
// Circuit 1 — transact_4x4 (src/verifiers/Verifier.sol)
// ---------------------------------------------------------------------------

uint256 constant VK1_DELTA_X1 = 7940460878566711747153190102215473803100318379673645338166116282024625460070;
uint256 constant VK1_DELTA_X2 = 21290486043588240563515441402248107510806983303297139685196732131949508455362;
uint256 constant VK1_DELTA_Y1 = 19143570905025336515925874475847019727033989067946574660014343042895396696204;
uint256 constant VK1_DELTA_Y2 = 1841758081245752348472426718101732297681344273760138114887262738432457428961;

uint256 constant VK1_IC0X = 7360541711783796843608457813112111222963345899090119919904655269242010521657;
uint256 constant VK1_IC0Y = 6429462842419169930476092936005251713569209662234419684887105529408106168312;
uint256 constant VK1_IC1X = 10905210383437816932874872511000099217003911566993907821914832302561796802828;
uint256 constant VK1_IC1Y = 11865015722019823213795606629949612552579100237458555870362098373571936699629;
uint256 constant VK1_IC2X = 6319743890118009224807460985140948755999623900045851108476905780655301875096;
uint256 constant VK1_IC2Y = 14968765478181676287681615849136721835595073950694150955949342566086616764095;

// ---------------------------------------------------------------------------
// Circuit 2 — tree_update_batch, MAX_L = 4 (src/verifiers/TreeUpdateBatchVerifier.sol)
// ---------------------------------------------------------------------------

uint256 constant VK2_DELTA_X1 = 18284299726000927826616710954310759407125299816366171821284177306861326073482;
uint256 constant VK2_DELTA_X2 = 2666798500826071192944210009612793454979079014904263864381114312740961103057;
uint256 constant VK2_DELTA_Y1 = 6554458342465618717720752301704989928310108038420244547298439302945544882766;
uint256 constant VK2_DELTA_Y2 = 11639318354414575580376067655964481587377800827424814136863393056290826214737;

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
bytes32 constant BATCH_DOMAIN = 0x58bae0a88d51dd3d6ac7b294936b8a0e2b10f36cc027c1288d34cb8737947f1b;
