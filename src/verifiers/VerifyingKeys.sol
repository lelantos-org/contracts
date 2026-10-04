// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Groth16 verifying-key constants for the two circuits a spend proves, copied
// verbatim from the snarkjs codegen verifiers as the single source of truth for
// `BatchedGroth16Verifier`.
//
// The values below, `Verifier.sol` and `TreeUpdateBatchVerifier.sol` are those
// of the `@lelantos-org/circuits` v0.17.0 release (public signals
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
// `alpha`, `beta` and `gamma` are shared: `4x6` is set up against
// `powersOfTau28_hez_final_17.ptau` and `tree_update_batch` against
// `powersOfTau28_hez_final_16.ptau`, both truncations of the same Hermez
// ceremony, so alpha and beta are the same points; snarkjs fixes gamma to the G2
// generator. Only `delta` and the `IC` points are per-circuit. The sharing lets
// the batched verifier fold the two `e(alpha, beta)` terms into one and the two
// `e(PI_i, gamma)` terms into one: six pairings instead of eight.
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

uint256 constant VK1_DELTA_X1 = 4591299447961830825293156141064672029028080196898315404228319922577858279916;
uint256 constant VK1_DELTA_X2 = 528794349809009979350557082514294347272891587158746525339380282096574394622;
uint256 constant VK1_DELTA_Y1 = 18553000299519152005504796574238829198719385810481413167600597900260442800339;
uint256 constant VK1_DELTA_Y2 = 10564908433112202900447991678422693340720531209055590939338373122358464119362;

uint256 constant VK1_IC0X = 13816254311718571174710801512355261556339207525964086124055117770063698112693;
uint256 constant VK1_IC0Y = 5029981637840532679567739172013614168819957212211412541406792212092570585422;
uint256 constant VK1_IC1X = 9574927536234911622419331185930629814507326367541457135863007002482736296361;
uint256 constant VK1_IC1Y = 16344832904341259829238420158587015416631457859817690763523119367110729391107;
uint256 constant VK1_IC2X = 8952468607721443954898799843150405758806899553777503325992545496491013960189;
uint256 constant VK1_IC2Y = 18954388950479956793276236987476960589799054003781590471714751876531275830607;
uint256 constant VK1_IC3X = 3558055682537354754927276967679349173413452460844051870644031755368695068427;
uint256 constant VK1_IC3Y = 430602886323409568473889520170901718534119775891748821313495613253529590538;

// ---------------------------------------------------------------------------
// Circuit 2 — tree_update_batch, MAX_L = 8 (src/verifiers/TreeUpdateBatchVerifier.sol)
// ---------------------------------------------------------------------------

uint256 constant VK2_DELTA_X1 = 17266862623044573508268467934130586715945457735903383711735031203234758760386;
uint256 constant VK2_DELTA_X2 = 14300257109121368622926810216875931672021171330916004459398846027398167459958;
uint256 constant VK2_DELTA_Y1 = 9622422775537648342642232890270806959215373080867564541265971324794715805426;
uint256 constant VK2_DELTA_Y2 = 14439109862278210443700690978453106821673318145077174764169458802959284118892;

uint256 constant VK2_IC0X = 19037342470316335688740176774818033589792790487745548603676142421664115439066;
uint256 constant VK2_IC0Y = 1746186893128657423051631958967595847991649942697750479314504841375757015462;
uint256 constant VK2_IC1X = 876300811634639705608082022806607489620848395001248061007026604997953546704;
uint256 constant VK2_IC1Y = 15163655103560601776953862311094177206370778975063035072663113329193445913769;
uint256 constant VK2_IC2X = 16099947931154303495375829999380519624148300642287937901471838429701908285927;
uint256 constant VK2_IC2Y = 21446403436821132375384774519337633284343595836425354930587010716037273669485;
uint256 constant VK2_IC3X = 14586170958406368915755666623208701499737351974239944098585683135094154806227;
uint256 constant VK2_IC3Y = 1641054206699422028967693930882737737319611952635673535517283560011395974845;

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
bytes32 constant BATCH_DOMAIN = 0x5f7c037314523702884f9caf1692a19b04335406facb8b076c5854796cd2e7cb;
