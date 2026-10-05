// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The parts of the ENS registry the names scripts and their fork tests use.
interface IEnsRegistry {
    function owner(bytes32 node) external view returns (address);
    function resolver(bytes32 node) external view returns (address);
    function setResolver(bytes32 node, address resolver) external;
    function setSubnodeRecord(bytes32 node, bytes32 label, address owner, address resolver, uint64 ttl) external;
}

/// The `.eth` registrar's ERC-721 surface: the registrant of an unwrapped name.
interface IEthBaseRegistrar {
    function ownerOf(uint256 tokenId) external view returns (address);
    function reclaim(uint256 tokenId, address owner) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// ENS addresses on Ethereum mainnet, and name encodings.
library Ens {
    IEnsRegistry internal constant REGISTRY = IEnsRegistry(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e);
    IEthBaseRegistrar internal constant ETH_REGISTRAR = IEthBaseRegistrar(0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85);
    /// `namehash("eth")`.
    bytes32 internal constant ETH_NODE = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;

    /// The node of `label` under `parent`: `namehash(label.parent)`.
    function subnode(bytes32 parent, string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(parent, keccak256(bytes(label))));
    }

    /// `name` in DNS wire format: each dot-separated label prefixed by its
    /// length, then the root label. Reverts on an empty or over-long label.
    function dnsEncode(string memory name) internal pure returns (bytes memory out) {
        bytes memory b = bytes(name);
        uint256 start = 0;
        for (uint256 i = 0; i <= b.length; ++i) {
            if (i != b.length && b[i] != ".") continue;
            uint256 len = i - start;
            require(len != 0 && len <= 63, "bad label in name");
            bytes memory label = new bytes(len);
            for (uint256 k = 0; k < len; ++k) {
                label[k] = b[start + k];
            }
            out = abi.encodePacked(out, uint8(len), label);
            start = i + 1;
        }
        out = abi.encodePacked(out, uint8(0));
    }
}
