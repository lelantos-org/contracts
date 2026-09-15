// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Permissive ERC-1271 wallet stub. Returns the magic value for any digest and
/// signature, so Permit2's `permitWitnessTransferFrom` accepts any signature
/// bytes when this code is etched at the signer's address. Used where the proof
/// fixture's payer is a hard-coded address with no private key: the proof
/// commits to that payer, so signature validation is routed through ERC-1271.
contract MockERC1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}
