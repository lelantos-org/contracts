// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Vm.sol";

import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { MockERC1271 } from "../mocks/MockERC1271.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";

/// The two cheatcode-driven stubs that most pool suites install verbatim in
/// their `setUp`: a permissive ERC-1271 wallet at the fixture payer, and a
/// verifier pair told to accept.
///
/// A library rather than a base contract so a suite that already extends
/// `Test` — or `MASPTestBase`, or nothing at all — can reach them without
/// changing what it inherits. `VM` is declared here rather than taken as a
/// parameter; a file-level `vm` constant would shadow the one `Test` provides
/// at every call site that imports this.
library Stubs {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// Etch the permissive ERC-1271 stub bytecode at `target`, so Permit2
    /// accepts any signature bytes claiming to come from it.
    ///
    /// The fixture payer is a hard-coded address with no private key: the
    /// SNARK proof commits to it, so a real signature cannot be produced.
    /// Permit2's `SignatureVerification` routes through `IERC1271` whenever the
    /// signer has code, which is what this exploits. Idempotent — re-etching at
    /// the same address has no effect.
    ///
    /// Suites whose subject *is* signature rejection must not call this; they
    /// pin a real ECDSA signer instead.
    function installPermissiveERC1271(address target) internal {
        VM.etch(target, address(new MockERC1271()).code);
    }

    /// Make both proof checks pass, for suites whose subject sits behind them.
    ///
    /// The spend path verifies through `verifyBatch`, answered by
    /// `MockBatchVerifier.setResult` rather than a mock — a blanket mock on
    /// that selector would also intercept the constructor probe of any `MASP`
    /// deployed later in the same test. The flush path goes through
    /// `IVerifier.verifyProof` on a stand-in that has code but no such
    /// function, so that one has to be mocked.
    function acceptAllProofs(IVerifier tub, MockBatchVerifier bv) internal {
        bv.setResult(true);
        acceptTreeUpdateProofs(tub, true);
    }

    /// Answer every `verifyProof` on `tub` with `ok`. Split out for the suites
    /// that flip the answer mid-test to drive the rejection branch.
    function acceptTreeUpdateProofs(IVerifier tub, bool ok) internal {
        VM.mockCall(address(tub), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(ok));
    }
}
