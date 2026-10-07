// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Groth16 verifying-key constants for the two circuits a spend proves, copied
// verbatim from the snarkjs codegen verifiers as the single source of truth for
// `BatchedGroth16Verifier`.
//
// The values below, `Verifier.sol` and `TreeUpdateBatchVerifier.sol` are those
// of the `@lelantos-org/circuits` v0.20.0 release (public signals
// `[y, digest, z]`), and the proof fixtures under `test/fixtures/` are proved
// with its keys. That release is a prototype: its trusted setup has a single
// contributor and is not safe for mainnet. A deployment holding real value
// needs the keys of a multi-party ceremony, replaced here together with both
// verifiers and every proof fixture; see `test/fixtures/README.md`.
//
// Circuit 1 is `4x6` (`Verifier.sol`), circuit 2 is `tree_update_batch`
// (`TreeUpdateBatchVerifier.sol`). `Verifier.sol` is not deployed; it is the
// provenance of the `VK1_*` constants below and the oracle in
// `test/verifiers/BatchedGroth16Verifier.t.sol`.
//
// `alpha`, `beta` and `gamma` are shared: both circuits are set up against
// `powersOfTau28_hez_final_16.ptau`, so alpha and beta are the same points;
// snarkjs fixes gamma to the G2 generator. Only `delta` and the `IC` points are
// per-circuit. The sharing lets the batched verifier fold the two
// `e(alpha, beta)` terms into one and the two `e(PI_i, gamma)` terms into one:
// six pairings instead of eight.
//
// Declared at file level rather than as library members: inline assembly can
// reference a file-level or contract-level `constant` of value type by bare
// identifier but cannot reference `Lib.CONST`.
//
// Rebuilding either circuit against a different ptau diverges the shared values,
// and the batched verifier then rejects every proof (fail-closed). Regenerate
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

uint256 constant VK1_DELTA_X1 = 16847764806174805684811775332861466745844160246678781558010263915412446693428;
uint256 constant VK1_DELTA_X2 = 14474417461302925912017876381033266935625229748427245954021132650109568750141;
uint256 constant VK1_DELTA_Y1 = 11343914776361278592028330370096196327599405884690394975667288509001711718326;
uint256 constant VK1_DELTA_Y2 = 13117613105122846487472405372218275853401758584301497448509847038476590397205;

uint256 constant VK1_IC0X = 20812299680272793904077023753384851875150207591088910091811211766704067775654;
uint256 constant VK1_IC0Y = 7227442971555976631802146058630240384121035316864593596066029743035212220893;
uint256 constant VK1_IC1X = 14541462581382330215849422906079186767630830424350405298991050747466931267467;
uint256 constant VK1_IC1Y = 1261125382474511821937443325550305692695621426049314883266718798776982654023;
uint256 constant VK1_IC2X = 17888020294129104026286329254962940846684640402907416305319629008614992957784;
uint256 constant VK1_IC2Y = 5370526806030538720892108467615628359355714596149126539990587034621660314585;
uint256 constant VK1_IC3X = 15348356002485236761645289560518578019657134624631103462897502894973620105593;
uint256 constant VK1_IC3Y = 15093659631705747672112679605732438909846470971980360242163200164684788486293;

// ---------------------------------------------------------------------------
// Circuit 2 — tree_update_batch, MAX_L = 8 (src/verifiers/TreeUpdateBatchVerifier.sol)
// ---------------------------------------------------------------------------

uint256 constant VK2_DELTA_X1 = 3488049732420094326737808537060699611211552346101830703587384227318624413017;
uint256 constant VK2_DELTA_X2 = 17264317134331721612243479630067951105188224393190038816541821117677330443585;
uint256 constant VK2_DELTA_Y1 = 3880073406792779867614949404021659286299726103108111730269159744891995132480;
uint256 constant VK2_DELTA_Y2 = 20284820763471017609199801820394793882707798318143443783961851253192869612755;

uint256 constant VK2_IC0X = 4636240639026840731562282914046136968062909353465604531829353710989597700695;
uint256 constant VK2_IC0Y = 4570162515565937092093529915421983461657571687798196582440542285115127525021;
uint256 constant VK2_IC1X = 4803591749399789589659734845627264967095827703836964970838364187261698870764;
uint256 constant VK2_IC1Y = 4230053666028076932557780725460802207687448987292954626696485387188923833826;
uint256 constant VK2_IC2X = 8879118376835321372560529264146690591984915388522221456791621452966297484913;
uint256 constant VK2_IC2Y = 11592099978968993454304915817111791288733785264080622969341508527796676640305;
uint256 constant VK2_IC3X = 11974910804771434515333481228452486628289424946476447283478159396053402377201;
uint256 constant VK2_IC3Y = 17888479862579181785019398525612062620955158491503978505244069768785671794345;

// ---------------------------------------------------------------------------
// Domain separator
// ---------------------------------------------------------------------------

// Prefix for the Fiat-Shamir transcript that derives the batching coefficient.
//
// Equal to `keccak256(abi.encode(...))` over all thirty-four verifying-key
// constants above, in this order:
//
//   VK_ALPHA_X, VK_ALPHA_Y,
//   VK_BETA_X1, VK_BETA_X2, VK_BETA_Y1, VK_BETA_Y2,
//   VK_GAMMA_X1, VK_GAMMA_X2, VK_GAMMA_Y1, VK_GAMMA_Y2,
//   VK1_DELTA_X1, VK1_DELTA_X2, VK1_DELTA_Y1, VK1_DELTA_Y2,
//   VK1_IC0X, VK1_IC0Y, VK1_IC1X, VK1_IC1Y, VK1_IC2X, VK1_IC2Y, VK1_IC3X, VK1_IC3Y,
//   VK2_DELTA_X1, VK2_DELTA_X2, VK2_DELTA_Y1, VK2_DELTA_Y2,
//   VK2_IC0X, VK2_IC0Y, VK2_IC1X, VK2_IC1Y, VK2_IC2X, VK2_IC2Y, VK2_IC3X, VK2_IC3Y
//
// A literal rather than a computed expression, because Solidity cannot fold
// `keccak256(abi.encode(...))` into a compile-time `constant`. A test recomputes
// it, so editing any key constant without regenerating this value fails the test
// suite.
//
// Defence in depth: the keys are fixed in bytecode, so a deployment with
// different keys is already a different contract. The prefix costs ~40 gas and
// keeps any other instantiation from sharing a challenge derivation.
bytes32 constant BATCH_DOMAIN = 0xc2e8bb62b45a070e431b9b2e8a352d94f4cdecb303659f4a35f0edb2da3f4eb6;
