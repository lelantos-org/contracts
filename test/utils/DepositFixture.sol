// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

/// Common scaffolding for the escrow path: `deposit`, `flushBatch` and
/// `cancelDeposit`.
///
/// The spend-side counterpart is `SpendFixture`. As there, the helpers fill the
/// fields a test rarely varies and leave the subject of a test to the caller:
/// every builder returns a memory struct the caller can modify before use.
///
/// Every deposit here carries the relayer fee note the pool always mints: zero
/// value, so asset 0, and commitment `FEE_CM`. A test pricing the relayer fee
/// sets `feeIn`, `feeAssetId` and the fee leaf itself.
///
/// Cheatcode-free, so the Halmos and Echidna targets can use it too.
library DepositFixture {
    /// The fee note commitment every fixture deposit carries.
    bytes32 internal constant FEE_CM = bytes32(uint256(0xfee));

    /// A deposit of `publicIn` units of `assetId` on this chain, with a
    /// zero-value relayer fee note.
    function request(uint64 assetId, uint64 publicIn, address payer, address recipient, bytes32 outCm)
        internal
        view
        returns (PubInputs.DepositRequest memory d)
    {
        d.chainId = block.chainid;
        d.publicAssetId = assetId;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = recipient;
        d.outCm = outCm;
        d.feeCm = FEE_CM;
    }

    /// A Permit2 signature for a payer carrying a permissive ERC-1271 stub
    /// (`Stubs.installPermissiveERC1271`), which accepts any signature bytes:
    /// no deadline, no cap on the total, no relayer fee.
    function sig(uint256 nonce) internal pure returns (MASP.Permit2Sig memory) {
        return sig(nonce, type(uint256).max, 0);
    }

    /// `sig` with explicit caps, for tests whose subject is the cap.
    function sig(uint256 nonce, uint256 maxTotal, uint256 maxFee) internal pure returns (MASP.Permit2Sig memory) {
        return MASP.Permit2Sig({
            nonce: nonce, deadline: type(uint256).max, maxTotal: maxTotal, maxFee: maxFee, signature: hex"00"
        });
    }

    /// The fee-note half of the escrow preimage for a fixture deposit, as
    /// `cancelDeposit` takes it.
    function feeNote() internal pure returns (PubInputs.FeeNote memory note) {
        note.feeCm = FEE_CM;
    }

    /// `n` identical `DepositMeta` entries.
    function metas(uint256 n, address payer, uint32 submittedAt, uint16 fbps)
        internal
        pure
        returns (MASP.DepositMeta[] memory m)
    {
        m = new MASP.DepositMeta[](n);
        for (uint256 i; i < n; ++i) {
            m[i] = MASP.DepositMeta({ payer: payer, submittedAt: submittedAt, fbps: fbps });
        }
    }

    /// A one-element id array, for flushing a single deposit.
    function ids(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }

    /// The header of a batch flushing `deposits` deposits at `startIndex`.
    /// Leaves are filled with `setDepositLeaves`.
    function batch(bytes32 oldRoot, bytes32 newRoot, uint64 startIndex, uint256 deposits)
        internal
        pure
        returns (PubInputs.TreeUpdateBatch memory tpi)
    {
        tpi.oldRoot = oldRoot;
        tpi.newRoot = newRoot;
        tpi.startIndex = startIndex;
        tpi.actualCount = uint64(deposits * PubInputs.LEAVES_PER_DEPOSIT);
    }

    /// Writes deposit `i`'s two leaves: the principal note, then the zero-value
    /// relayer fee note. The fee leaf's asset is 0 because the circuit
    /// canonicalises the asset of a leaf whose Pedersen binding cannot see it,
    /// and `flushBatch` requires the match.
    function setDepositLeaves(
        PubInputs.TreeUpdateBatch memory tpi,
        uint256 i,
        bytes32 cm,
        uint256[2] memory cvDep,
        uint64 assetId,
        uint64 publicIn
    ) internal pure {
        uint256 slot = i * PubInputs.LEAVES_PER_DEPOSIT;
        tpi.cms[slot] = cm;
        tpi.cvDeps[slot] = cvDep;
        tpi.leafAsset[slot] = assetId;
        tpi.leafPublicIn[slot] = publicIn;
        tpi.isDeposit[slot] = 1;
        tpi.cms[slot + 1] = FEE_CM;
        tpi.leafAsset[slot + 1] = 0;
        tpi.leafPublicIn[slot + 1] = 0;
        tpi.isDeposit[slot + 1] = 1;
    }

    /// `setDepositLeaves` for a deposit with no value commitment.
    function setDepositLeaves(
        PubInputs.TreeUpdateBatch memory tpi,
        uint256 i,
        bytes32 cm,
        uint64 assetId,
        uint64 publicIn
    ) internal pure {
        uint256[2] memory zero;
        setDepositLeaves(tpi, i, cm, zero, assetId, publicIn);
    }
}
