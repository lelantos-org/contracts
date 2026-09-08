// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";

import { EscrowFlowBase } from "./EscrowFlowBase.sol";
import { newPoolImplementation, poolInitCalldata } from "./PoolDeployer.sol";
import { uniformBps } from "./FeeArrays.sol";

/// The pool behind a proxy this suite controls, so the upgrade surface can be
/// driven: queue, cancel, activate, pause. Deposits, flushes and accrued state
/// come from `EscrowFlowBase`; only the proxy wiring is added here.
abstract contract MASPUpgradeTestBase is EscrowFlowBase {
    uint256 internal constant UPGRADE_DELAY = 30 days;
    uint256 internal constant MAX_PAUSE = 7 days;

    MASP internal impl;
    DelayedUpgradeProxy internal proxy;

    address internal admin = makeAddr("proxyAdmin");

    /// A dedicated proxy, so `admin`, the window and the pause ceiling are under
    /// this suite's control.
    function _deployTestPool() internal override returns (MASP) {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = _genesisAsset();
        impl = newPoolImplementation();
        bytes memory initData = poolInitCalldata(
            IVerifier(address(tubVerifier)),
            IBatchVerifier(address(batchVerifier)),
            ISignatureTransfer(permit2),
            ids,
            tokens,
            scales,
            uniformBps(1, FEE_BPS),
            uniformBps(1, FEE_BPS),
            treasury,
            poolOwner
        );
        proxy = new DelayedUpgradeProxy(address(impl), initData, admin, UPGRADE_DELAY, MAX_PAUSE);
        return MASP(address(proxy));
    }
}
