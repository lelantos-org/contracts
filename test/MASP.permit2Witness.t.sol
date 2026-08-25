// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IEIP712 } from "permit2/src/interfaces/IEIP712.sol";
import { SignatureVerification } from "permit2/src/libraries/SignatureVerification.sol";

import { MASPTestBase } from "./utils/MASPTestBase.sol";
import { MASP } from "../src/MASP.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { SpendFixture } from "./utils/SpendFixture.sol";

/// Regression for the Permit2 witness binding shape used by `deposit`.
///
/// Catches silent drift between:
///   * the on-chain typehash (`DEPOSIT_WITNESS_TYPEHASH`),
///   * the EIP-712 sub-type-string passed to Permit2
///     (`DEPOSIT_WITNESS_TYPE_STRING`),
///   * the `piHash = keccak256(abi.encode(d, aux, feeAux))` preimage shape
///     that wallets sign over.
///
/// Any of those getting out of sync silently breaks signature scoping (a
/// leaked Permit2 sig could be re-targeted at a different deposit payload).
contract MASPPermit2WitnessTest is MASPTestBase {
    /// The Permit2 sub-type-string format requires the witness type appended
    /// immediately before `TokenPermissions(...)` so Permit2's domain hash
    /// absorbs the witness shape. See permit2/src/libraries/PermitHash.sol.
    string internal constant PERMIT2_TOKEN_PERMISSIONS_SUFFIX = "TokenPermissions(address token,uint256 amount)";
    string internal constant WITNESS_INNER_TYPE = "MASPDeposit(bytes32 piHash)";
    string internal constant WITNESS_ARG_PREFIX = "MASPDeposit witness)";

    function test_typehash_matchesInnerType() public view {
        assertEq(
            masp.DEPOSIT_WITNESS_TYPEHASH(),
            keccak256(bytes(WITNESS_INNER_TYPE)),
            "DEPOSIT_WITNESS_TYPEHASH must equal keccak256 of the inner MASPDeposit type"
        );
    }

    function test_typeString_isPermit2SubTypeShape() public view {
        string memory ts = masp.DEPOSIT_WITNESS_TYPE_STRING();
        string memory expected = string.concat(WITNESS_ARG_PREFIX, WITNESS_INNER_TYPE, PERMIT2_TOKEN_PERMISSIONS_SUFFIX);
        assertEq(ts, expected, "type-string must match Permit2 sub-type concatenation");
    }

    function test_typeString_containsInnerType() public view {
        bytes memory ts = bytes(masp.DEPOSIT_WITNESS_TYPE_STRING());
        bytes memory needle = bytes(WITNESS_INNER_TYPE);
        assertTrue(_indexOf(ts, needle) != type(uint256).max, "inner witness type must appear in sub-type-string");
    }

    function test_typeString_endsWithTokenPermissions() public view {
        bytes memory ts = bytes(masp.DEPOSIT_WITNESS_TYPE_STRING());
        bytes memory suffix = bytes(PERMIT2_TOKEN_PERMISSIONS_SUFFIX);
        require(ts.length >= suffix.length, "type-string shorter than suffix");
        for (uint256 i = 0; i < suffix.length; ++i) {
            assertEq(ts[ts.length - suffix.length + i], suffix[i], "TokenPermissions suffix must be last");
        }
    }

    /// Golden-hash regression: pins the `keccak256(abi.encode(d, aux, feeAux))`
    /// derivation against a fixed fixture. If the `DepositRequest` struct
    /// layout, the `AuxValidation.Output` shape, or the number of aux payloads
    /// bound into the witness changes, the digest drifts and this fails.
    ///
    /// The pin is a literal, not a recomputation of the same expression: a test
    /// that recomputes its own expected value asserts nothing.
    ///
    /// Update the constant only when the wallet signature shape intentionally
    /// changes; coordinate with off-chain signers + circuits.
    bytes32 internal constant PI_HASH_GOLDEN = 0x75bc606de1a3dc7c372602227f7c3e0ae9463795498704dce1d992af6bed5e3a;

    function test_piHash_isStableForFixedFixture() public pure {
        PubInputs.DepositRequest memory d = _fixtureDeposit();
        AuxValidation.Output memory aux = _fixtureAux();
        AuxValidation.Output memory feeAux = _fixtureFeeAux();

        assertEq(keccak256(abi.encode(d, aux, feeAux)), PI_HASH_GOLDEN, "piHash drifted from the pinned fixture");
    }

    /// The fee leg is inside the signed preimage. Both halves are probed: the
    /// request's own fee fields, and the fee payload passed alongside it.
    function test_piHash_bindsTheFeeLeg() public pure {
        PubInputs.DepositRequest memory d = _fixtureDeposit();
        AuxValidation.Output memory aux = _fixtureAux();

        d.feeCm = bytes32(uint256(0xbeef));
        assertTrue(keccak256(abi.encode(d, aux, _fixtureFeeAux())) != PI_HASH_GOLDEN, "feeCm not bound");

        d = _fixtureDeposit();
        d.feeIn += 1;
        assertTrue(keccak256(abi.encode(d, aux, _fixtureFeeAux())) != PI_HASH_GOLDEN, "feeIn not bound");

        d = _fixtureDeposit();
        AuxValidation.Output memory feeAux = _fixtureFeeAux();
        feeAux.ciphertext = hex"c0ffee";
        assertTrue(keccak256(abi.encode(d, aux, feeAux)) != PI_HASH_GOLDEN, "feeAux not bound");
    }

    function _fixtureDeposit() private pure returns (PubInputs.DepositRequest memory d) {
        d.chainId = 31337;
        d.publicAssetId = 1;
        d.publicIn = 100;
        d.payer = address(0xface);
        d.recipient = address(0xb0b);
        d.outCm = bytes32(uint256(0x1111));
        d.cvDep[0] = 0xaaaa;
        d.cvDep[1] = 0xbbbb;
        d.rcv = 0xeeee;
        d.feeIn = 7;
        d.feeCm = bytes32(uint256(0x2222));
        d.feeCvDep[0] = 0xcccc;
        d.feeCvDep[1] = 0xdddd;
        d.feeRcv = 0xffff;
    }

    /// The depositor's payload. A deposit mints two leaves, so a second one
    /// rides alongside it — see `_fixtureFeeAux`.
    function _fixtureAux() private pure returns (AuxValidation.Output memory aux) {
        aux.clueRx = 0x111;
        aux.clueRy = 0x112;
        aux.ephPubX = 0x113;
        aux.ephPubY = 0x114;
        aux.ciphertext = hex"deadbeef";
    }

    /// The relayer's payload. Deliberately distinct from `_fixtureAux` in every
    /// field: identical fixtures would make the two arguments interchangeable
    /// and hide a swapped or dropped `feeAux`.
    function _fixtureFeeAux() private pure returns (AuxValidation.Output memory aux) {
        aux.clueRx = 0x221;
        aux.clueRy = 0x222;
        aux.ephPubX = 0x223;
        aux.ephPubY = 0x224;
        aux.ciphertext = hex"feedface";
    }

    function _indexOf(bytes memory hay, bytes memory needle) private pure returns (uint256) {
        if (needle.length == 0 || needle.length > hay.length) return type(uint256).max;
        for (uint256 i = 0; i <= hay.length - needle.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        return type(uint256).max;
    }

    // --- end-to-end signature scoping ---------------------------------------
    //
    // The pins above are test-local arithmetic: they prove the preimage shape
    // is stable, not that `deposit` actually pulls against it. These sign a
    // real Permit2 witness with a real key and let Permit2 be the judge, so a
    // drift between `_permit2Pull`'s `piHash` and what a wallet signed shows up
    // as a rejected deposit rather than as a green test.

    uint256 internal constant SIGNER_PK = 0xA11CE;

    function _signer() internal pure returns (address) {
        return vm.addr(SIGNER_PK);
    }

    /// A deposit the fixture registry can actually settle, payable by `_signer`.
    function _liveRequest() internal view returns (PubInputs.DepositRequest memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = 100;
        d.payer = _signer();
        d.recipient = address(0xb0b);
        d.outCm = bytes32(uint256(0x1111));
        d.feeIn = 7;
        d.feeCm = bytes32(uint256(0x2222));
        d.feeCvDep = [uint256(0xcccc), uint256(0xdddd)];
        d.feeRcv = 0xffff;
    }

    function _liveTotal(PubInputs.DepositRequest memory d) internal pure returns (uint256) {
        uint256 inAmt = uint256(d.publicIn) * SCALE;
        return inAmt + (inAmt * FEE_BPS) / 10_000 + uint256(d.feeIn) * SCALE;
    }

    function _fundSigner(uint256 total) internal {
        token.mint(_signer(), total);
        vm.prank(_signer());
        token.approve(permit2, type(uint256).max);
    }

    /// The EIP-712 digest Permit2 checks for `permitWitnessTransferFrom`, built
    /// from the type-string MASP passes it. Mirrors `PermitHash.hashWithWitness`
    /// with `msg.sender` fixed to the pool, which is the spender.
    function _permitDigest(MASP.Permit2Sig memory sig, bytes32 piHash) internal view returns (bytes32) {
        bytes32 witness = keccak256(abi.encode(masp.DEPOSIT_WITNESS_TYPEHASH(), piHash));
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                masp.DEPOSIT_WITNESS_TYPE_STRING()
            )
        );
        bytes32 permitted =
            keccak256(abi.encode(keccak256(bytes(PERMIT2_TOKEN_PERMISSIONS_SUFFIX)), address(token), sig.maxTotal));
        bytes32 structHash = keccak256(abi.encode(typeHash, permitted, address(masp), sig.nonce, sig.deadline, witness));
        return keccak256(abi.encodePacked("\x19\x01", IEIP712(permit2).DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(MASP.Permit2Sig memory sig, bytes32 piHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, _permitDigest(sig, piHash));
        return abi.encodePacked(r, s, v);
    }

    function _liveSig(uint256 total) internal pure returns (MASP.Permit2Sig memory) {
        return MASP.Permit2Sig({ nonce: 0, deadline: type(uint256).max, maxTotal: total, signature: hex"" });
    }

    /// Baseline: a signature over the full preimage settles.
    function test_deposit_acceptsSignatureOverFullPreimage() public {
        PubInputs.DepositRequest memory d = _liveRequest();
        AuxValidation.Output[4] memory aux = SpendFixture.validAux();
        uint256 total = _liveTotal(d);
        _fundSigner(total);

        MASP.Permit2Sig memory sig = _liveSig(total);
        sig.signature = _sign(sig, keccak256(abi.encode(d, aux[0], aux[1])));

        uint256 id = masp.deposit(d, sig, aux[0], aux[1]);
        assertEq(token.balanceOf(address(masp)), total, "pool pulled the signed total");
        assertTrue(masp.escrowed(id) != bytes32(0), "escrow recorded");
    }

    /// The regression the golden pin cannot catch on its own: a wallet still
    /// signing the pre-fee-note preimage must be rejected, not silently
    /// accepted against a payload it never saw.
    function test_revert_deposit_signatureOmitsFeeAux() public {
        PubInputs.DepositRequest memory d = _liveRequest();
        AuxValidation.Output[4] memory aux = SpendFixture.validAux();
        uint256 total = _liveTotal(d);
        _fundSigner(total);

        MASP.Permit2Sig memory sig = _liveSig(total);
        // Stale shape: request and depositor payload only.
        sig.signature = _sign(sig, keccak256(abi.encode(d, aux[0])));

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        masp.deposit(d, sig, aux[0], aux[1]);
    }

    /// Signature scoping in the other direction: the fee payload cannot be
    /// swapped for another after signing. It is what the relayer decrypts to
    /// find the note it is owed, so a relayer-chosen substitute would strand
    /// the payer's funds in an unspendable leaf.
    function test_revert_deposit_feeAuxSwappedAfterSigning() public {
        PubInputs.DepositRequest memory d = _liveRequest();
        AuxValidation.Output[4] memory aux = SpendFixture.validAux();
        uint256 total = _liveTotal(d);
        _fundSigner(total);

        MASP.Permit2Sig memory sig = _liveSig(total);
        sig.signature = _sign(sig, keccak256(abi.encode(d, aux[0], aux[1])));

        // Well-formed, so it clears `AuxValidation` and the witness is the only
        // thing left to reject it.
        AuxValidation.Output memory substitute = SpendFixture.uniformAux(hex"0002")[0];
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        masp.deposit(d, sig, aux[0], substitute);
    }

    /// Same scoping over the request itself: swapping the fee note's
    /// commitment redirects the payer-funded note to whoever submits. It leaves
    /// the pulled amount untouched, so the witness is the only thing that
    /// rejects it — raising `feeIn` instead would be stopped earlier by
    /// Permit2's signed amount cap.
    function test_revert_deposit_feeCmSwappedAfterSigning() public {
        PubInputs.DepositRequest memory d = _liveRequest();
        AuxValidation.Output[4] memory aux = SpendFixture.validAux();
        uint256 total = _liveTotal(d);
        _fundSigner(total);

        MASP.Permit2Sig memory sig = _liveSig(total);
        sig.signature = _sign(sig, keccak256(abi.encode(d, aux[0], aux[1])));

        d.feeCm = bytes32(uint256(0xbad));
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        masp.deposit(d, sig, aux[0], aux[1]);
    }
}
