// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { LelantosNameRegistrar } from "./LelantosNameRegistrar.sol";

/// Serves the handles of a `LelantosNameRegistrar` as subnames of one ENS
/// parent name: `<label>.<parent>` resolves the text record `KEY` to the
/// handle's value.
///
/// An ENSIP-10 wildcard resolver, set as the parent's resolver in the ENS
/// registry. No subname exists there; clients that follow ENSIP-10 (the
/// Universal Resolver) reach `resolve` for every name under the parent and for
/// the parent itself.
///
/// Stateless and ownerless. One is deployed per parent, all over the same
/// registrar, so replacing or adding one changes no handle.
contract LelantosNameResolver {
    bytes4 private constant ERC165_ID = 0x01ffc9a7;
    /// `IExtendedResolver.resolve(bytes,bytes)`.
    bytes4 private constant EXTENDED_RESOLVER_ID = 0x9061b923;
    /// `ITextResolver.text(bytes32,string)`.
    bytes4 private constant TEXT_SELECTOR = 0x59d1d43c;
    uint256 private constant SELECTOR_LENGTH = 4;

    LelantosNameRegistrar public immutable REGISTRAR;
    /// keccak256 and length of the parent in DNS wire format.
    bytes32 public immutable PARENT_NAME_HASH;
    uint256 public immutable PARENT_NAME_LENGTH;
    bytes32 public immutable TEXT_KEY_HASH;
    /// Answers queries for the parent itself, so it keeps ordinary records.
    /// Zero when it has none.
    address public immutable FALLBACK_RESOLVER;

    /// The parent in DNS wire format, e.g. `\x08lelantos\x03xyz\x00`.
    bytes public parentName;
    /// The one text key served for a handle.
    string public textKey;

    /// The resolver does not implement this record type. The name and
    /// signature are ENS's, which the Universal Resolver recognizes.
    error UnsupportedResolverProfile(bytes4 selector);
    /// `name` is neither the parent nor a direct subname of it.
    error UnreachableName(bytes name);
    error MalformedParentName();
    error ZeroAddress();

    constructor(
        LelantosNameRegistrar registrar,
        bytes memory parentName_,
        string memory textKey_,
        address fallbackResolver
    ) {
        if (address(registrar) == address(0)) revert ZeroAddress();
        if (!_isDnsName(parentName_)) revert MalformedParentName();
        REGISTRAR = registrar;
        PARENT_NAME_HASH = keccak256(parentName_);
        PARENT_NAME_LENGTH = parentName_.length;
        TEXT_KEY_HASH = keccak256(bytes(textKey_));
        FALLBACK_RESOLVER = fallbackResolver;
        parentName = parentName_;
        textKey = textKey_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == ERC165_ID || id == EXTENDED_RESOLVER_ID;
    }

    /// ENSIP-10 entry point. `name` is in DNS wire format and is
    /// authoritative; the node inside `data` is ignored.
    ///
    /// - The parent: `data` is forwarded to the fallback resolver.
    /// - `<label>.<parent>` with `text(node, KEY)`: the handle's value, empty
    ///   when the label is unregistered or cleared. Any other key is empty.
    /// - Any other record type reverts `UnsupportedResolverProfile`.
    /// - Any other name reverts `UnreachableName`. This includes a name under a
    ///   different parent pointed at this contract.
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory) {
        if (_isParent(name)) return _forward(data);

        bytes32 labelHash = _subnameLabelHash(name);
        bytes4 selector = _selector(data);
        if (selector != TEXT_SELECTOR) revert UnsupportedResolverProfile(selector);

        (, string memory key) = abi.decode(data[SELECTOR_LENGTH:], (bytes32, string));
        if (keccak256(bytes(key)) != TEXT_KEY_HASH) return abi.encode("");
        return abi.encode(REGISTRAR.valueOf(labelHash));
    }

    function _isParent(bytes calldata name) private view returns (bool) {
        return name.length == PARENT_NAME_LENGTH && keccak256(name) == PARENT_NAME_HASH;
    }

    /// keccak256 of the label of `name`, which must be `<label>.<parent>`.
    /// DNS wire format is length-prefixed, so byte 0 is the label's length and
    /// the parent must be exactly what follows the label.
    function _subnameLabelHash(bytes calldata name) private view returns (bytes32) {
        uint256 n = name.length;
        uint256 labelLength = n == 0 ? 0 : uint8(name[0]);
        if (labelLength == 0 || n != 1 + labelLength + PARENT_NAME_LENGTH || !_isParent(name[1 + labelLength:])) {
            revert UnreachableName(name);
        }
        return keccak256(name[1:1 + labelLength]);
    }

    /// The function selector of `data`, zero when it is shorter than one.
    function _selector(bytes calldata data) private pure returns (bytes4) {
        return data.length < SELECTOR_LENGTH ? bytes4(0) : bytes4(data[:SELECTOR_LENGTH]);
    }

    /// The fallback resolver's answer to `data`, with its revert bubbled.
    function _forward(bytes calldata data) private view returns (bytes memory) {
        address fallbackResolver = FALLBACK_RESOLVER;
        if (fallbackResolver == address(0)) revert UnsupportedResolverProfile(_selector(data));
        (bool ok, bytes memory result) = fallbackResolver.staticcall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }

    /// Whether `name` is one or more labels of 1 to 63 bytes followed by the
    /// root label, with nothing after it.
    function _isDnsName(bytes memory name) private pure returns (bool) {
        uint256 n = name.length;
        uint256 i = 0;
        uint256 labels = 0;
        while (i < n) {
            uint256 len = uint8(name[i]);
            if (len == 0) return labels != 0 && i == n - 1;
            if (len > 63) return false;
            i += 1 + len;
            ++labels;
        }
        return false;
    }
}
