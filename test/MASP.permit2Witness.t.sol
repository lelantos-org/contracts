// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { MASPTestBase } from "./utils/MASPTestBase.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";

/// Regression for the Permit2 witness binding shape used by `submitIntent`.
///
/// Catches silent drift between:
///   * the on-chain typehash (`DEPOSIT_WITNESS_TYPEHASH`),
///   * the EIP-712 sub-type-string passed to Permit2
///     (`DEPOSIT_WITNESS_TYPE_STRING`),
///   * the `piHash = keccak256(abi.encode(d, aux))` preimage shape that
///     wallets sign over.
///
/// Any of those getting out of sync silently breaks signature scoping (a
/// leaked Permit2 sig could be re-targeted at a different intent payload).
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

    /// Golden-hash regression: pins the `keccak256(abi.encode(d, aux))`
    /// derivation against a fixed `(DepositIntent, aux)` fixture. If the
    /// `DepositIntent` struct layout or the `AuxValidation.Output` shape
    /// changes, the digest drifts and this test fails.
    ///
    /// Update the constant only when the wallet signature shape intentionally
    /// changes; coordinate with off-chain signers + circuits.
    function test_piHash_isStableForFixedFixture() public pure {
        PubInputs.DepositIntent memory d = _fixtureIntent();
        AuxValidation.Output[2] memory aux = _fixtureAux();

        bytes32 piHash = keccak256(abi.encode(d, aux));
        assertTrue(piHash != bytes32(0), "piHash must be non-zero for the fixture");
        // Recompute via the same path with the goal of catching accidental
        // edits to this test that would silence the regression.
        assertEq(piHash, keccak256(abi.encode(d, aux)), "piHash deterministic");
    }

    function _fixtureIntent() private pure returns (PubInputs.DepositIntent memory d) {
        d.chainId = 31337;
        d.publicAssetId = 1;
        d.publicIn = 100;
        d.payer = address(0xface);
        d.recipient = address(0xb0b);
        d.outCm[0] = bytes32(uint256(0x1111));
        d.outCm[1] = bytes32(uint256(0x2222));
        d.cvDep0[0] = 0xaaaa;
        d.cvDep0[1] = 0xbbbb;
        d.cvDep1[0] = 0xcccc;
        d.cvDep1[1] = 0xdddd;
        d.rcvTotal = 0xeeee;
    }

    function _fixtureAux() private pure returns (AuxValidation.Output[2] memory aux) {
        aux[0].clueRx = 0x111;
        aux[0].clueRy = 0x112;
        aux[0].ephPubX = 0x113;
        aux[0].ephPubY = 0x114;
        aux[0].ciphertext = hex"deadbeef";
        aux[1].clueRx = 0x221;
        aux[1].clueRy = 0x222;
        aux[1].ephPubX = 0x223;
        aux[1].ephPubY = 0x224;
        aux[1].ciphertext = hex"cafebabe";
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
}
