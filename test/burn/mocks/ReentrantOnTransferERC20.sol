// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// ERC-20 that re-enters a configured target on `transfer`.
///
/// The repo's `ReentrantMockERC20` hooks `transferFrom`, which is the wrong leg
/// for `FeeBurner.buy` — the lot is paid out with `transfer`, and that is the
/// last interaction in the call, i.e. exactly the point a hostile fee token would
/// try to re-enter from.
contract ReentrantOnTransferERC20 is ERC20 {
    address public target;
    bytes public reenterCalldata;
    bool public armed;

    constructor() ERC20("RT", "RT") { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function arm(address t, bytes calldata data) external {
        target = t;
        reenterCalldata = data;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(reenterCalldata);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return super.transfer(to, amount);
    }
}
