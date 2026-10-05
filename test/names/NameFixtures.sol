// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Values the names suites share: the parties, one handle, and the encoders of
/// what a resolver is asked.
abstract contract NameFixtures {
    address internal constant OWNER = address(0x0A11CE);
    address internal constant TREASURY = address(0x7EA5);
    /// The key behind every handle these suites register.
    uint256 internal constant CONTROLLER_KEY = 0xC0FFEE;
    string internal constant TEXT_KEY = "xyz.lelantos.address";
    string internal constant LABEL = "mehow";

    /// 195 characters, the length of a shielded address.
    string internal constant VALUE =
        "lelantos1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0jqgfzyvjz2f38yq4z5zcyz5r3w9gkzur2p3xxgmr8vcnyvd3k2enxve5ksct5v9nxjmr9v3hhyetjw3skwatpw35kumn0wd6hy6twvdjhqar9wfjx7atswpshqatnwdjhy";

    /// The `minGas` a wallet binds for the call leg `[approve, register]` with a
    /// 195-byte value. The SDK's `REGISTER_NAME_MIN_GAS` must equal it.
    uint256 internal constant REGISTER_MIN_GAS = 360_000;
    /// What a production fee token may cost over the plain ERC-20 the gas test
    /// uses. `fork/RegistrationGas.fork.t.sol` holds mainnet USDC to it.
    uint256 internal constant FEE_TOKEN_PREMIUM = 20_000;

    /// `label` in front of `parent`, both in DNS wire format.
    function _subname(string memory label, bytes memory parent) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(bytes(label).length), label, parent);
    }

    /// `text(node, key)` calldata.
    function _textCall(bytes32 node, string memory key) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("text(bytes32,string)", node, key);
    }
}
