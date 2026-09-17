// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IMASPPool } from "../../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../../src/libs/AuxValidation.sol";

/// Minimal token that can deliver a solver-chosen balance delta.
///
/// `MaspEscrowSatellite` measures every recorded amount as the difference
/// between two `balanceOf` reads, so its proofs need balances that move by a
/// symbolic quantity. OpenZeppelin's `ERC20` would add allowance bookkeeping and
/// EIP-712 logic that none of these properties need.
///
/// The satellite calls only `balanceOf`. `credit` and `debit` let the pool mock
/// below move balances without an allowance ledger.
contract MockEscrowToken {
    mapping(address account => uint256) public balanceOf;

    function credit(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function debit(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }
}

/// Stand-in for the pool a satellite escrows into.
///
/// A satellite reaches `MASP` through three functions: `depositAuthorized` to
/// escrow, `escrowed` to distinguish a live deposit from a settled one, and
/// `cancelDeposit` to cancel. It observes the effect of the first and last only
/// as a token balance delta, since it cannot see the pool's deposit fee or the
/// relayer note.
///
/// The real pool's escrow behaviour is covered by `MASPEscrow.symbolic.t.sol`.
/// Here the subject is the satellite's accounting, which must hold for any
/// amount the pool moves, so both amounts are settable and the proofs quantify
/// over them.
///
/// On a yield asset the refund is the escrowed units valued at the current
/// index, capped at the pull, so it can fall below the recorded amount by
/// rounding or a venue loss, and the satellite knows the figure only from the
/// pool's return value. The delivered and reported refunds are therefore set
/// independently, so a proof can quantify over a pool that misreports.
contract MockEscrowPool {
    MockEscrowToken public immutable TOKEN;

    mapping(uint256 id => bytes32) public escrowed;

    uint256 public nextId = 1;
    /// Taken from the satellite on `depositAuthorized`.
    uint256 public pull;
    /// Delivered to the satellite on `cancelDeposit`.
    uint256 public refund;
    /// Reported by `cancelDeposit` as the refund paid.
    uint256 public reported;

    /// Registry token per asset id, for callers that resolve one through
    /// `asset`. Unset ids resolve to the zero address.
    mapping(uint64 id => address token) public assetToken;

    constructor(MockEscrowToken token) {
        TOKEN = token;
    }

    /// Asset ids that report a yield venue.
    mapping(uint64 id => bool) public isYieldAsset;

    function setYieldAsset(uint64 id, bool yield_) external {
        isYieldAsset[id] = yield_;
    }

    function setAssetToken(uint64 id, address token) external {
        assetToken[id] = token;
    }

    /// The registry entry of `id`; only its token is populated.
    function asset(uint64 id) external view returns (IMASPPool.AssetEntry memory entry) {
        entry.token = assetToken[id];
    }

    function setPull(uint256 v) external {
        pull = v;
    }

    function setRefund(uint256 v) external {
        refund = v;
    }

    function setReported(uint256 v) external {
        reported = v;
    }

    /// Marks `id` live, as `depositAuthorized` would. Paired with the
    /// satellite's `seed`, it lets a cancel proof quantify over the recorded
    /// amount without fixing it through a deposit.
    function open(uint256 id) external {
        escrowed[id] = bytes32(id);
    }

    /// Marks `id` settled without paying anything (the flush case), which a
    /// cancel must refuse.
    function settle(uint256 id) external {
        escrowed[id] = bytes32(0);
    }

    function depositAuthorized(
        PubInputs.DepositRequest calldata,
        AuxValidation.Output calldata,
        AuxValidation.Output calldata
    ) external returns (uint256 id) {
        id = nextId++;
        escrowed[id] = bytes32(id);
        TOKEN.debit(msg.sender, pull);
        TOKEN.credit(address(this), pull);
    }

    function cancelDeposit(
        uint256 id,
        uint48,
        bytes32,
        uint256[2] calldata,
        uint64,
        uint16,
        address,
        uint32,
        PubInputs.FeeNote calldata
    ) external returns (uint256, uint256) {
        escrowed[id] = bytes32(0);
        TOKEN.credit(msg.sender, refund);
        // No second-token refund: a satellite escrows single-token deposits.
        return (reported, 0);
    }
}
