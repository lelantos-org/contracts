// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PubInputs } from "../../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../../src/libs/AuxValidation.sol";

/// The smallest ERC-20 that can deliver a solver-chosen balance delta.
///
/// `MaspEscrowSatellite` measures every amount it records as the difference
/// between two `balanceOf` reads, so proofs about that accounting need a token
/// whose balances move by a symbolic quantity. OpenZeppelin's `ERC20` would
/// serve, but it drags allowance bookkeeping and `ERC20Permit`'s EIP-712
/// machinery into paths none of these properties are about.
///
/// `balanceOf` is the only function the satellite calls on it. `credit` and
/// `debit` exist for the pool stand-in below to move balances without an
/// allowance ledger, which is the part being elided.
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
/// A satellite reaches `MASP` through exactly three functions: it escrows with
/// `depositAuthorized`, reads `escrowed` to tell a live deposit from a settled
/// one, and cancels with `cancelDeposit`. It observes the result of the first
/// and last only as a token balance delta — it cannot see the pool's deposit
/// fee or the relayer note, which is why it measures rather than recomputes.
///
/// Everything the real pool does behind those calls is proved in
/// `MASPEscrow.symbolic.t.sol`. What is under proof here is the satellite's own
/// accounting, which has to hold whatever the pool moves — so both amounts are
/// settable and the proofs quantify over them.
///
/// That quantification is the point. On a yield asset the refund is the
/// escrowed units valued at the current index, so it exceeds the amount pulled
/// at submit by whatever the funds earned while escrowed, and neither figure is
/// known to the satellite in advance. A proof that fixed the refund to the pull
/// would miss the case the floor check exists to allow.
contract MockEscrowPool {
    MockEscrowToken public immutable TOKEN;

    mapping(uint256 id => bytes32) public escrowed;

    uint256 public nextId = 1;
    /// Taken from the satellite on `depositAuthorized`.
    uint256 public pull;
    /// Returned to the satellite on `cancelDeposit`.
    uint256 public refund;

    constructor(MockEscrowToken token) {
        TOKEN = token;
    }

    function setPull(uint256 v) external {
        pull = v;
    }

    function setRefund(uint256 v) external {
        refund = v;
    }

    /// Marks `id` live, standing in for the escrow a `depositAuthorized` would
    /// have left. Paired with the satellite's own `seed`, it lets a cancel
    /// proof quantify over the recorded amount without reaching it through a
    /// deposit that would fix that amount.
    function open(uint256 id) external {
        escrowed[id] = bytes32(id);
    }

    /// Marks `id` settled without paying anything — the flush case, which a
    /// cancel must then refuse.
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
    ) external {
        escrowed[id] = bytes32(0);
        TOKEN.credit(msg.sender, refund);
    }
}
