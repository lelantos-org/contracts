// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// ERC-20 that re-enters a configured target on `transferFrom`, for exercising
/// the pool's `nonReentrant` guards against a malicious registered token.
contract ReentrantMockERC20 is ERC20 {
    address public target;
    bytes public reenterCalldata;
    bool public armed;

    constructor() ERC20("R", "R") { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    /// Configures the call made back into the target on the next
    /// `transferFrom`, and arms it.
    function arm(address t, bytes calldata data) external {
        target = t;
        reenterCalldata = data;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(reenterCalldata);
            if (!ok) {
                // Bubble the inner revert so SafeERC20 surfaces it verbatim.
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return super.transferFrom(from, to, amount);
    }
}
