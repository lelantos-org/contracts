// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// Permissive ERC-1271 wallet stub. Returns the magic value for any digest +
/// signature pair, so Permit2's `permitWitnessTransferFrom` accepts any
/// "signature" when `vm.etch`'d at the claimed signer's address. Used in
/// tests where the proof fixture's payer is a hard-coded address with no
/// associated private key: the SNARK proof's payer commitment cannot be
/// regenerated, so signature validation is routed through ERC-1271 instead.
contract MockERC1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}
