// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MockAllowanceTransfer } from "./mocks/MockAllowanceTransfer.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployPoolUniform, singleAsset } from "../utils/PoolDeployer.sol";

/// Deploys a real `MASP` behind the real proxy with the dependencies a symbolic
/// proof cannot afford to explore replaced by mocks.
///
/// Free function rather than a base-contract method so a fixture that needs a
/// different asset — `NativeAdapter`'s wrapped-native pool — can reuse the
/// wiring without inheriting the escrow helpers it has no use for.
///
/// What is mocked, and why each is sound to mock:
///
/// - **Permit2** — an allowance ledger, a nonce bitmap and an EIP-712 signature
///   check. No property proved against this pool depends on any of it, and the
///   token movement it performs stays real.
/// - **Both Groth16 verifiers** — a pairing check is out of reach for a solver.
///   The spend verifier answers `true`, which matters only in that it must not
///   be the reason a call fails; `initialize` also probes it, so the address
///   must carry code.
///
/// Every proof built on this either rejects before reaching a verifier, or is
/// about state the verifier has no bearing on.
function deployMockedPool(IERC20 asset, uint16 feeBps, address permit2, address treasury, address owner)
    returns (MASP)
{
    MockBatchVerifier spendVerifier = new MockBatchVerifier();
    spendVerifier.setResult(true);
    MockBatchVerifier tubVerifier = new MockBatchVerifier();

    (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
        singleAsset(asset, PoolConstants.ASSET_ID, PoolConstants.SCALE);

    return deployPoolUniform(
        IVerifier(address(tubVerifier)),
        IBatchVerifier(address(spendVerifier)),
        ISignatureTransfer(permit2),
        ids,
        tokens,
        scales,
        feeBps,
        treasury,
        owner
    );
}

/// Values shared by every pool fixture, in a library so the free function above
/// and the base contract below agree on them by construction.
library PoolConstants {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);
    address internal constant RECIPIENT = address(0xb0b);
}

/// Shared fixture for the proofs that drive a real `MASP`.
///
/// Five test contracts deployed a pool and built the same deposit request from
/// the same constants; this holds that once, so a change to the escrow shape is
/// one edit rather than five, and a fixture that silently stops being valid
/// cannot do so in only some of them.
///
/// Named without `Symbolic` on purpose: `match-contract` in `halmos.toml` scopes
/// a run to contracts matching that word, and a fixture is not a test.
abstract contract PoolFixture is GuardAsserts {
    uint64 internal constant ASSET_ID = PoolConstants.ASSET_ID;
    uint256 internal constant SCALE = PoolConstants.SCALE;
    uint16 internal constant FEE_BPS = PoolConstants.FEE_BPS;

    address internal constant TREASURY = PoolConstants.TREASURY;
    address internal constant OWNER = PoolConstants.OWNER;
    address internal constant RECIPIENT = PoolConstants.RECIPIENT;

    /// The genesis empty-tree root, and so the only known root in a pool that
    /// has never advanced.
    bytes32 internal constant EMPTY_ROOT = 0x1cf92e62b512433b35f0064d537576b0184cad5fa7ab64201cd8084ee2dc171f;

    /// The concrete half of the escrow preimage `_submit` writes. `cm` is left
    /// to the caller and is expected to be symbolic — see `_submit`.
    uint48 internal constant PUBLIC_IN = 100;
    uint256 internal constant CV_DEP_X = 0x11;
    uint256 internal constant CV_DEP_Y = 0x22;
    uint48 internal constant FEE_IN = 7;
    bytes32 internal constant FEE_CM = bytes32(uint256(0xfee5));
    uint256 internal constant FEE_CV_DEP_X = 0x33;
    uint256 internal constant FEE_CV_DEP_Y = 0x44;

    MASP internal masp;
    MockERC20 internal token;
    MockAllowanceTransfer internal permit2;

    /// Block the escrow under test was submitted at, recorded by `_submit`.
    uint32 internal submittedAt;

    function setUp() public virtual {
        token = new MockERC20("M", "M", 18);
        permit2 = new MockAllowanceTransfer();
        masp = deployMockedPool(IERC20(address(token)), FEE_BPS, address(permit2), TREASURY, OWNER);

        // This contract is the payer, and so also a *contract* payer — the case
        // `cancelDeposit` restricts to self-service.
        token.mint(address(this), type(uint128).max);
        token.approve(address(permit2), type(uint256).max);
    }

    // --- deposit fixtures ---------------------------------------------------

    /// A deposit request that passes every guard, with `cm` supplied by the
    /// caller.
    function _request(bytes32 cm) internal view returns (PubInputs.DepositRequest memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = PUBLIC_IN;
        d.payer = address(this);
        d.recipient = RECIPIENT;
        d.outCm = cm;
        d.cvDep = [CV_DEP_X, CV_DEP_Y];
        d.feeIn = FEE_IN;
        d.feeCm = FEE_CM;
        d.feeCvDep = [FEE_CV_DEP_X, FEE_CV_DEP_Y];
    }

    /// A concrete, valid aux payload: the Baby-Jubjub prime-order generator in
    /// both point slots and a minimal well-formed ciphertext.
    ///
    /// Concrete on purpose. `AuxValidation.validate` runs `isOnCurve` and
    /// `isLowOrder`, `mulmod` chains over a 254-bit field — the one thing in
    /// this path a solver cannot carry symbolically. With the points fixed the
    /// whole check constant-folds, and the aux payload is not what these proofs
    /// are about; `test/fuzz/BabyJubJub.fuzz.t.sol` covers it.
    function _aux() internal pure returns (AuxValidation.Output[6] memory) {
        return SpendFixture.validAux();
    }

    /// Submits the escrow a proof starts from, recording its block.
    ///
    /// `cm` is expected to be symbolic, and that is load-bearing rather than
    /// incidental. Halmos models `keccak256` as an uninterpreted function plus
    /// an injectivity axiom, which relates uninterpreted hash terms *to each
    /// other* — it does not tie such a term to a hash computed concretely.
    /// Submit an entirely concrete preimage and `escrowed[id]` holds a literal
    /// constant, leaving the solver free to pick a symbolic preimage whose
    /// uninterpreted hash equals it: a forged match, and a counterexample
    /// against a contract that is correct. With one field symbolic both sides
    /// are uninterpreted terms and the proof means what it claims.
    function _submit(bytes32 cm) internal returns (uint256 id) {
        submittedAt = uint32(block.number);
        AuxValidation.Output[6] memory aux = _aux();
        id = masp.depositAuthorized(_request(cm), aux[0], aux[1]);
    }

    /// The fee note matching what `_submit` escrowed.
    function _submittedFeeNote() internal pure returns (PubInputs.FeeNote memory) {
        return PubInputs.FeeNote({ feeIn: FEE_IN, feeCm: FEE_CM, feeCvDep: [FEE_CV_DEP_X, FEE_CV_DEP_Y] });
    }

    /// Cancels with the preimage `_submit` escrowed under `cm`.
    function _cancelSubmitted(uint256 id, bytes32 cm) internal returns (bool ok) {
        (ok,) = address(masp)
            .call(
                abi.encodeCall(
                    MASP.cancelDeposit,
                    (
                        id,
                        PUBLIC_IN,
                        cm,
                        [CV_DEP_X, CV_DEP_Y],
                        ASSET_ID,
                        FEE_BPS,
                        address(this),
                        submittedAt,
                        _submittedFeeNote()
                    )
                )
            );
    }

    // --- assertions ---------------------------------------------------------
}
