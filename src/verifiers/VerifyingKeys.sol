// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Groth16 verifying-key constants for the two circuits a spend proves, copied
// verbatim from the snarkjs codegen verifiers as the single source of truth for
// `BatchedGroth16Verifier`.
//
// Circuit 1 is `4x6` (`Verifier.sol`), circuit 2 is `tree_update_batch`
// (`TreeUpdateBatchVerifier.sol`). `Verifier.sol` is not deployed; it is the
// provenance of the `VK1_*` constants below and the oracle in
// `test/BatchedGroth16Verifier.t.sol`.
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

uint256 constant VK1_DELTA_X1 = 20442596146274625695075512216713289688847031082417268255084593251952480783809;
uint256 constant VK1_DELTA_X2 = 14877719245748628783208683540198419483902232715073619186049926526541662044007;
uint256 constant VK1_DELTA_Y1 = 318749546300264217398643496350082127797895251132572846887041387647562621308;
uint256 constant VK1_DELTA_Y2 = 15631013081002670639837965319263718852167882402820564988335626401571350754975;

uint256 constant VK1_IC0X = 9000079759558951107176795198911526252309875328582927078672158524201737527497;
uint256 constant VK1_IC0Y = 16699515151812402935373842389253930320231651425753059260188241154704734345081;
uint256 constant VK1_IC1X = 760535443569538096383015975828355841762125442690430701485963291121291904631;
uint256 constant VK1_IC1Y = 7932695176175249399956027105804835587653373982039484875570202314640982562619;
uint256 constant VK1_IC2X = 20647453367783461496338622955155213265058892179997963455075973482888307024431;
uint256 constant VK1_IC2Y = 4181312152269065102443332273825630254341908484380830381195062903153741278339;

// ---------------------------------------------------------------------------
// Circuit 2 — tree_update_batch, MAX_L = 8 (src/verifiers/TreeUpdateBatchVerifier.sol)
// ---------------------------------------------------------------------------

uint256 constant VK2_DELTA_X1 = 17097758488400347251375841493004931769896972743087591552112566323086110585244;
uint256 constant VK2_DELTA_X2 = 19611409791536690948756639548373465073680297538225423734586623261336060095125;
uint256 constant VK2_DELTA_Y1 = 6302418883244718097648677540771658539773297804417357391545645616516110460542;
uint256 constant VK2_DELTA_Y2 = 12576267304426249645176438240076546872331810861889219806264143641657163398500;

uint256 constant VK2_IC0X = 15129712634548804640612573371577755003482250893388068499408520043597122252992;
uint256 constant VK2_IC0Y = 340369080627655191151538390456712524588567350610195453485197684835232943236;
uint256 constant VK2_IC1X = 90227995590229748041195938139373560466552529516015793848056753658267155618;
uint256 constant VK2_IC1Y = 18671907450626730533587247589804479564681355498955644556237836100410620668370;
uint256 constant VK2_IC2X = 17094657212265104857531481492542193862391877662224410671295054576492719992696;
uint256 constant VK2_IC2Y = 14564949236383033408106893930755664272275001327150684429999417179898928017009;

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
// it, so editing any key constant without regenerating this value fails the test
// suite.
//
// Defence in depth: the keys are fixed in bytecode, so a deployment with
// different keys is already a different contract. The prefix costs ~40 gas and
// keeps any other instantiation from sharing a challenge derivation.
bytes32 constant BATCH_DOMAIN = 0x5121d41dc8f43e2e6a38582a963812feace27c7c992c689f219700c367d75d15;
