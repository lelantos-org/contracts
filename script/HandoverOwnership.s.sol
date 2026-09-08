// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { MASP } from "../src/MASP.sol";
import { DelayedUpgradeProxy } from "../src/DelayedUpgradeProxy.sol";
import { SwapWrapper } from "../src/swap/SwapWrapper.sol";

/// Moves the pool, the wrapper and the pool proxy under governance. Signed by
/// the current owner EOA and run separately from any deploy.
///
/// Order matters: treasuries are repointed first, while the EOA can still do so
/// in one transaction rather than through a proposal.
///
/// Ownership transfer is single-step, so there is no acceptance transaction and
/// a mistyped address is unrecoverable. Every write is read back and asserted.
///
/// Prerequisite: governance must be able to pass a proposal. With no delegated
/// weight a Timelock-owned pool has no working administrator. Gate on delegated
/// weight above quorum and on a dry-run proposal completing the full pipeline.
///
/// Config: `GOV_CONFIG` supplies `masp` and `swapWrapper`; `PROTOCOL_ADMIN` and
/// `FEE_BURNER` come from the deploy's KEY=value output.
contract HandoverOwnership is Script {
    string constant DEFAULT_CONFIG = "script/config/mainnet.gov.json";

    function run() external {
        string memory j = vm.readFile(vm.envOr("GOV_CONFIG", DEFAULT_CONFIG));
        MASP masp = MASP(vm.parseJsonAddress(j, ".masp"));
        SwapWrapper wrapper = SwapWrapper(payable(vm.parseJsonAddress(j, ".swapWrapper")));
        address protocolAdmin = vm.envAddress("PROTOCOL_ADMIN");
        address feeBurner = vm.envAddress("FEE_BURNER");

        require(protocolAdmin.code.length != 0, "protocolAdmin has no code");
        require(feeBurner.code.length != 0, "feeBurner has no code");

        DelayedUpgradeProxy proxy = DelayedUpgradeProxy(payable(address(masp)));

        vm.startBroadcast();
        // 1-2: treasuries first, so the first fee routing needs no proposal.
        masp.setTreasury(feeBurner);
        wrapper.setTreasury(feeBurner);
        // 3-4: then ownership of the pool and the wrapper. One-way.
        masp.transferOwnership(protocolAdmin);
        wrapper.transferOwnership(protocolAdmin);
        // 5: the proxy admin, which holds the right to queue, cancel and
        // activate upgrades and to pause. The deployer holds it until this
        // point, since `ProtocolAdmin` cannot predate the proxy.
        proxy.changeProxyAdmin(protocolAdmin);
        vm.stopBroadcast();

        // 6: read back and assert. A silent misfire here is unrecoverable.
        require(masp.owner() == protocolAdmin, "masp owner mismatch");
        require(wrapper.owner() == protocolAdmin, "wrapper owner mismatch");
        require(masp.treasury() == feeBurner, "masp treasury mismatch");
        require(wrapper.treasury() == feeBurner, "wrapper treasury mismatch");
        require(proxy.proxyAdmin() == protocolAdmin, "proxy admin mismatch");

        console2.log(string.concat("MASP_OWNER=", vm.toString(masp.owner())));
        console2.log(string.concat("WRAPPER_OWNER=", vm.toString(wrapper.owner())));
        console2.log(string.concat("MASP_TREASURY=", vm.toString(masp.treasury())));
        console2.log(string.concat("WRAPPER_TREASURY=", vm.toString(wrapper.treasury())));
        console2.log(string.concat("PROXY_ADMIN=", vm.toString(proxy.proxyAdmin())));
    }
}
