// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { PoolFixture } from "./PoolFixture.sol";

/// Symbolic proofs for the deposit-side request guards.
///
/// `deposit` and `depositAuthorized` share `_validateDeposit`, which validates
/// unauthenticated calldata before any token moves or escrow record is written.
/// Every rejection precedes the Baby-Jubjub curve checks at the end of the
/// function, so the guard set is provable for every malformed request.
///
/// Each proof pins the revert selector. `check_deposit_fixtureIsAccepted` shows
/// the fixture itself is accepted, so a rejection cannot come from an unrelated
/// fixture defect.
///
/// The pool and its mocks come from `PoolFixture`.
contract MASPDepositGuardsSymbolicTest is PoolFixture {
    /// A request that passes every guard. Each proof below breaks exactly one
    /// field, so a rejection is attributable to that field alone.
    function _valid() internal view returns (PubInputs.DepositRequest memory) {
        return _request(bytes32(uint256(0xdead)));
    }

    function _deposit(PubInputs.DepositRequest memory d) internal returns (bool ok, bytes memory ret) {
        AuxValidation.Output[6] memory aux = _aux();
        (ok, ret) = address(masp).call(abi.encodeCall(MASP.depositAuthorized, (d, aux[0], aux[1])));
    }

    function _rejectedWith(PubInputs.DepositRequest memory d, bytes4 expected) internal {
        (bool ok, bytes memory ret) = _deposit(d);
        _assertRejected(ok, ret, expected);
    }

    /// The fixture is accepted, so each rejection proof below is attributable to
    /// the field it breaks.
    function check_deposit_fixtureIsAccepted() public {
        (bool ok,) = _deposit(_valid());
        assertTrue(ok);
    }

    // --- amount bounds -----------------------------------------------------

    /// A deposit amount must be non-zero and fit `uint48`, the width the escrow
    /// digest and the tree-update circuit narrow it to. Proved over the full
    /// declared `uint64`, covering both sides of the `uint48` max boundary.
    function check_deposit_rejectsOutOfRangeAmount(uint64 publicIn) public {
        vm.assume(publicIn == 0 || publicIn > type(uint48).max);

        PubInputs.DepositRequest memory d = _valid();
        d.publicIn = publicIn;

        _rejectedWith(d, publicIn == 0 ? MASP.MustHaveDeposit.selector : MASP.PublicInTooLarge.selector);
    }

    /// The relayer's fee note has the same width bound. It may be zero (the leaf
    /// is minted either way), so only the ceiling applies.
    function check_deposit_rejectsOutOfRangeFeeNote(uint64 feeIn) public {
        vm.assume(feeIn > type(uint48).max);

        PubInputs.DepositRequest memory d = _valid();
        d.feeIn = feeIn;

        _rejectedWith(d, MASP.PublicInTooLarge.selector);
    }

    // --- party and commitment binding --------------------------------------

    /// `depositAuthorized` pulls against the payer's allowance, so the caller must
    /// be the payer; otherwise any address that approved the pool through Permit2
    /// could be drained by a third party.
    function check_depositAuthorized_rejectsAnyCallerButThePayer(address caller) public {
        vm.assume(caller != address(this) && caller != address(0));

        PubInputs.DepositRequest memory d = _valid();

        vm.prank(caller);
        _rejectedWith(d, MASP.PayerNotSender.selector);
    }

    /// A zero payer or recipient is rejected. A zero recipient would escrow funds
    /// nobody can claim.
    function check_deposit_rejectsZeroParties(bool zeroPayer) public {
        PubInputs.DepositRequest memory d = _valid();
        if (zeroPayer) {
            d.payer = address(0);
        } else {
            d.recipient = address(0);
        }

        // `ZeroPayer` fires inside validation, before the caller-is-payer check.
        _rejectedWith(d, zeroPayer ? MASP.ZeroPayer.selector : MASP.ZeroRecipient.selector);
    }

    /// Neither of the deposit's two leaves may carry a zero commitment; a zero
    /// commitment is not a well-formed note.
    function check_deposit_rejectsZeroCommitment(bool zeroOut) public {
        PubInputs.DepositRequest memory d = _valid();
        if (zeroOut) {
            d.outCm = bytes32(0);
        } else {
            d.feeCm = bytes32(0);
        }

        _rejectedWith(d, MASP.ZeroCm.selector);
    }

    /// A request built for another chain cannot be replayed here.
    function check_deposit_rejectsForeignChainId(uint256 chainId) public {
        vm.assume(chainId != block.chainid);

        PubInputs.DepositRequest memory d = _valid();
        d.chainId = chainId;

        _rejectedWith(d, MASP.BadChainId.selector);
    }

    // --- registry gating ---------------------------------------------------

    /// Every asset id the registry does not hold is rejected.
    function check_deposit_rejectsUnregisteredAsset(uint64 assetId) public {
        vm.assume(assetId != ASSET_ID);

        PubInputs.DepositRequest memory d = _valid();
        d.publicAssetId = assetId;

        (bool ok, bytes memory ret) = _deposit(d);
        _assertRejected(ok, ret, AssetRegistry.UnknownAsset.selector);
    }

    /// A disabled asset takes no new deposits.
    ///
    /// That a disabled asset stays spendable and withdrawable requires a
    /// successful spend and is covered by `test/masp/MASP.assets.t.sol`.
    function check_deposit_rejectsDisabledAsset() public {
        vm.prank(OWNER);
        masp.setAssetDisabled(ASSET_ID, true);

        (bool ok, bytes memory ret) = _deposit(_valid());
        _assertRejected(ok, ret, AssetRegistry.AssetDisabled.selector);
    }
}
