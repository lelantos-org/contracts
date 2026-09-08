// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { NullifierSet } from "../../src/NullifierSet.sol";
import { NullifierSetHarness } from "../utils/NullifierSetHarness.sol";

import { NullifierSetSpec } from "./generated/NullifierSetSpec.sol";
import { NullifierSetSpecReplay } from "./generated/NullifierSetSpecReplay.sol";

/// Driver for [spec/nullifier_set.qnt](../../spec/nullifier_set.qnt).
///
/// Drives the same `NullifierSetHarness` the symbolic suite proves against
/// ([test/symbolic/NullifierSet.symbolic.t.sol](../symbolic/NullifierSet.symbolic.t.sol)),
/// so the two agree on the surface and differ only in what they establish: that
/// suite proves the isolation property for a *pair* of nullifiers over all
/// 2^256 values, this one runs a *sequence* and re-reads the whole spent set
/// after every call.
///
/// `abstract` so Foundry does not collect it as a test contract; the generated
/// `NullifierSetTraces` inherits it and holds one test per trace.
abstract contract NullifierSetReplay is NullifierSetSpecReplay {
    /// Must match `NULLIFIERS` in the spec, in ascending order.
    ///
    /// `_project` enumerates this to rebuild the spent set: `spent()` is a
    /// mapping lookup and cannot be iterated, so the reconstruction is complete
    /// only because the model's domain is finite and known. If the spec widens
    /// its domain and this does not, the projection would quietly stop seeing
    /// the extra values — `_assertDomain` turns that into a hard failure.
    function _domain() internal pure returns (uint256[7] memory) {
        return [uint256(0), 1, 255, 256, 257, 511, 512];
    }

    NullifierSetHarness internal nfs;

    function setUp() public virtual {
        nfs = new NullifierSetHarness();
    }

    function apply_(NullifierSetSpec.Action action, NullifierSetSpec.Picks memory picks) external override {
        require(msg.sender == address(this), "self-call only");
        _assertDomain(picks.nf);

        if (action == NullifierSetSpec.Action.Consume) {
            nfs.consume(bytes32(picks.nf));
        } else if (action == NullifierSetSpec.Action.ConsumeSpent) {
            // The model asserts a rejection, so the driver has to assert one
            // too. Without `expectRevert` the call would simply revert, the
            // replay would report it as an enabledness divergence, and the
            // negative path could never be expressed.
            vm.expectRevert(NullifierSet.DoubleSpend.selector);
            nfs.consume(bytes32(picks.nf));
        } else {
            revert("unhandled action");
        }
    }

    /// Every field is a live read; this driver keeps no shadow state.
    function _project() internal view override returns (NullifierSetSpec.State memory s) {
        uint256[7] memory domain = _domain();

        uint256 count = 0;
        for (uint256 i = 0; i < domain.length; i++) {
            if (nfs.spent(bytes32(domain[i]))) count++;
        }

        // Ascending because `_domain()` is ascending, which is the order the
        // generator sorted the model's set into.
        s.spentSet = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < domain.length; i++) {
            if (nfs.spent(bytes32(domain[i]))) s.spentSet[j++] = domain[i];
        }
    }

    /// A pick outside the modelled domain means the spec and this driver have
    /// drifted apart, and the projection above would be incomplete. Fail on
    /// that directly rather than letting it surface as a missing set member.
    function _assertDomain(uint256 nf) private pure {
        uint256[7] memory domain = _domain();
        for (uint256 i = 0; i < domain.length; i++) {
            if (domain[i] == nf) return;
        }
        revert("driver: nullifier outside the spec's domain");
    }
}
