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
/// value, so asset 0, and inner commitment `FEE_INNER`. A test pricing the
/// relayer fee sets `feeIn`, `feeAssetId` and the fee leaf itself.
///
/// The `bytes32` a deposit carries is its note's `inner`, not a note
/// commitment: the batch circuit builds the leaf from the public amount and
/// `inner`. These fixtures use arbitrary words, since no test here opens one.
///
/// Cheatcode-free, so the Halmos and Echidna targets can use it too.
library DepositFixture {
    /// The fee note `inner` every fixture deposit carries.
    bytes32 internal constant FEE_INNER = bytes32(uint256(0xfee));

    /// A deposit of `publicIn` units of `assetId` on this chain, with a
    /// zero-value relayer fee note.
    function request(uint64 assetId, uint64 publicIn, address payer, address recipient, bytes32 inner)
        internal
        view
        returns (PubInputs.DepositRequest memory d)
    {
        d.chainId = block.chainid;
        d.publicAssetId = assetId;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = recipient;
        d.inner = inner;
        d.feeInner = FEE_INNER;
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
        note.feeInner = FEE_INNER;
    }

    /// `n` identical `DepositMeta` entries for plain-asset deposits, which
    /// carry no refund cap.
    function metas(uint256 n, address payer, uint32 submittedAt, uint16 fbps)
        internal
        pure
        returns (MASP.DepositMeta[] memory m)
    {
        m = new MASP.DepositMeta[](n);
        for (uint256 i; i < n; ++i) {
            m[i] = MASP.DepositMeta({ payer: payer, submittedAt: submittedAt, fbps: fbps, pulled: 0 });
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
    /// relayer fee note. The fee leaf's asset is 0, "no asset", which is what
    /// submit requires of a zero-value note and so what the escrow digest
    /// holds; `flushBatch` requires the match.
    function setDepositLeaves(
        PubInputs.TreeUpdateBatch memory tpi,
        uint256 i,
        bytes32 inner,
        uint64 assetId,
        uint64 publicIn
    ) internal pure {
        uint256 slot = i * PubInputs.LEAVES_PER_DEPOSIT;
        tpi.cms[slot] = inner;
        tpi.leafAsset[slot] = assetId;
        tpi.leafPublicIn[slot] = publicIn;
        tpi.isDeposit[slot] = 1;
        tpi.cms[slot + 1] = FEE_INNER;
        tpi.leafAsset[slot + 1] = 0;
        tpi.leafPublicIn[slot + 1] = 0;
        tpi.isDeposit[slot + 1] = 1;
    }
}
