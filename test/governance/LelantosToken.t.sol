// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { Votes } from "@openzeppelin/contracts/governance/utils/Votes.sol";

import { LelantosToken } from "../../src/governance/LelantosToken.sol";

/// The governance token's two load-bearing properties: that nothing can inflate
/// it, and that its ERC-6372 clock is coherent. Both are relied on by
/// `LelantosGovernor` and neither is checked by the compiler.
contract LelantosTokenTest is Test {
    LelantosToken internal token;

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal constant RECIPIENT = address(0xA11CE);

    address internal alice;
    uint256 internal alicePk;

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("alice");
        token = new LelantosToken("Lelantos", "LNT", SUPPLY, RECIPIENT);
    }

    // ============== Supply ===================================================

    function test_mintsFullSupplyToRecipient() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(RECIPIENT), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalBurned(), 0);
    }

    /// There must be no way to inflate supply. The ABI carries no `mint`, so this
    /// pins the absence at the dispatch level rather than trusting the source.
    function test_hasNoMintFunction() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok, "a mint entry point exists");
        (bool ok2,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok2, "token must have no owner");
    }

    function test_burnReducesSupplyAndIsReported() public {
        vm.prank(RECIPIENT);
        token.burn(100e18);
        assertEq(token.totalSupply(), SUPPLY - 100e18);
        assertEq(token.totalBurned(), 100e18);
    }

    function test_constructorRejectsZeroRecipient() public {
        vm.expectRevert(LelantosToken.ZeroRecipient.selector);
        new LelantosToken("L", "L", SUPPLY, address(0));
    }

    function test_constructorRejectsZeroSupply() public {
        vm.expectRevert(LelantosToken.ZeroSupply.selector);
        new LelantosToken("L", "L", 0, RECIPIENT);
    }

    // ============== ERC-6372 clock ===========================================

    /// Warps use absolute timestamps throughout this suite. Under `via_ir` the
    /// optimizer may cache `block.timestamp` within a call — legal, since it cannot
    /// change mid-transaction — which `vm.warp` then invalidates, so
    /// `vm.warp(block.timestamp + n)` is not reliable in a test body.
    function test_clockIsTimestamp() public {
        vm.warp(1_000);
        assertEq(token.clock(), uint48(1_000));
        vm.warp(13_345);
        assertEq(token.clock(), uint48(13_345));
    }

    /// `Votes.CLOCK_MODE` reverts `ERC6372InconsistentClock` when `clock()` is
    /// overridden without it. Overriding exactly one is a silent, total break of
    /// governance, so the pair is pinned here.
    function test_clockModeDoesNotRevertAndDeclaresTimestamp() public view {
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
    }

    // ============== Delegation ===============================================

    /// A balance is not voting weight until it is delegated. This is the single
    /// most common governance-launch surprise.
    function test_balanceIsNotVotesUntilDelegated() public {
        assertEq(token.getVotes(RECIPIENT), 0, "undelegated balance must carry no weight");
        vm.prank(RECIPIENT);
        token.delegate(RECIPIENT);
        assertEq(token.getVotes(RECIPIENT), SUPPLY);
    }

    function test_getPastVotesRevertsForFutureLookup() public {
        vm.warp(1_000);
        vm.expectRevert(abi.encodeWithSelector(Votes.ERC5805FutureLookup.selector, uint256(1_000), uint48(1_000)));
        token.getPastVotes(RECIPIENT, 1_000);
    }

    /// Quorum reads `getPastTotalSupply`. `Votes._transferVotingUnits` checkpoints
    /// the total only on mint and burn — a transfer must not move it, or the quorum
    /// denominator would wander with ordinary activity.
    function test_pastTotalSupplyTracksBurnsButNotTransfers() public {
        vm.warp(1_000);
        vm.prank(RECIPIENT);
        token.transfer(alice, 1_000e18);

        vm.warp(2_000);
        assertEq(token.getPastTotalSupply(1_999), SUPPLY, "transfer moved total supply");

        vm.prank(alice);
        token.burn(1_000e18);

        vm.warp(3_000);
        assertEq(token.getPastTotalSupply(2_999), SUPPLY - 1_000e18, "burn did not lower total supply");
        // The burn is visible from its own timepoint onward, not only later.
        assertEq(token.getPastTotalSupply(2_000), SUPPLY - 1_000e18);
        assertEq(token.getPastTotalSupply(1_999), SUPPLY, "burn leaked backwards");
    }

    // ============== Nonces diamond ===========================================

    /// `ERC20Permit` and `ERC20Votes` both inherit `Nonces`. If the override picked
    /// the wrong parent the two would keep separate counters, and a signature valid
    /// for one path would be replayable against the other.
    function test_permitAndDelegateBySigShareOneNonce() public {
        vm.prank(RECIPIENT);
        token.transfer(alice, 1e18);
        assertEq(token.nonces(alice), 0);

        _permit(alice, alicePk, address(this), 1e18, block.timestamp + 1 days);
        assertEq(token.allowance(alice, address(this)), 1e18);
        assertEq(token.nonces(alice), 1, "permit did not advance the shared nonce");

        _delegateBySig(alicePk, alice, 1, block.timestamp + 1 days);
        assertEq(token.delegates(alice), alice);
        assertEq(token.nonces(alice), 2, "delegateBySig did not advance the same counter");
    }

    function _permit(address owner, uint256 pk, address spender, uint256 value, uint256 deadline) private {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                token.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        token.permit(owner, spender, value, deadline, v, r, s);
    }

    function _delegateBySig(uint256 pk, address delegatee, uint256 nonce, uint256 expiry) private {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"), delegatee, nonce, expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        token.delegateBySig(delegatee, nonce, expiry, v, r, s);
    }

    /// The Governor reaches the token through this interface.
    function test_supportsIERC5805Surface() public view {
        IERC5805 t = IERC5805(address(token));
        assertEq(t.getVotes(RECIPIENT), 0);
    }
}
