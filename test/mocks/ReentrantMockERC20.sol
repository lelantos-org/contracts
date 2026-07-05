// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// ERC20 that re-enters a configured target on `transferFrom`. Used to verify
/// `MASP.transact`'s `nonReentrant` guard fires against a malicious token in
/// the registry.
contract ReentrantMockERC20 is ERC20 {
    address public target;
    bytes public reenterCalldata;
    bool public armed;

    constructor() ERC20("R", "R") { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    /// Configure the call that will be made back into the target on the next
    /// `transferFrom`. Set `armed = true` to actually trigger it.
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
