// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { BaseGovernanceDeploy } from "../../script/base/BaseGovernanceDeploy.s.sol";
import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";
import { BatchedGroth16Verifier } from "../../src/verifiers/BatchedGroth16Verifier.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { deployPoolUniform, singleAsset } from "../utils/PoolDeployer.sol";

contract GovDeployHarness is BaseGovernanceDeploy {
    function deployStack(GovParams memory p) external returns (GovStack memory) {
        // The harness itself sends the role calls, so it is the deployer.
        return _deployGovernanceStack(p, address(this));
    }
}

/// Runs the deploy path in-process and asserts the resulting role table.
///
/// The deploy's last transaction is an irreversible renounce, so the failure
/// modes checked here — an ungranted proposer, a deployer retaining admin, a
/// burner owned by the wrong address — are unrecoverable on a live chain.
contract DeployGovernanceTest is Test {
    GovDeployHarness internal harness;
    MASP internal masp;
    SwapWrapper internal wrapper;
    address internal permit2;
    MockERC20 internal token;

    address internal guardian = makeAddr("guardian");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        harness = new GovDeployHarness();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("T", "T", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), 1, 1e10);

        masp = deployPoolUniform(
            IVerifier(address(new TreeUpdateBatchGroth16Verifier())),
            IBatchVerifier(address(new BatchedGroth16Verifier())),
            ISignatureTransfer(permit2),
            ids,
            tokens,
            scales,
            25,
            address(0xfee),
            address(this)
        );
        wrapper = new SwapWrapper(IMASPPool(address(masp)), IAllowanceTransfer(permit2), address(this), address(0xfee));
    }

    function _params() internal view returns (BaseGovernanceDeploy.GovParams memory p) {
        p.tokenName = "Lelantos";
        p.tokenSymbol = "LNT";
        p.totalSupply = 1_000_000_000e18;
        p.tokenRecipient = recipient;
        p.timelockMinDelay = 3 days;
        p.votingDelay = 2 days;
        p.votingPeriod = 7 days;
        p.proposalThreshold = 2_500_000e18;
        p.quorumNumerator = 3;
        p.guardian = guardian;
        p.masp = address(masp);
        p.swapWrapper = address(wrapper);
        p.burnBps = 10_000;
        p.secondaryTreasury = address(0);
        p.auctionHalfLife = 1 hours;
        p.auctionMaxHalvings = 12;
        p.auctionRestartMultBps = 20_000;
    }

    /// After the deploy the deployer retains no role.
    function test_deployerRetainsNothing() public {
        BaseGovernanceDeploy.GovStack memory s = harness.deployStack(_params());

        assertFalse(
            s.timelock.hasRole(s.timelock.DEFAULT_ADMIN_ROLE(), address(harness)), "deployer kept timelock admin"
        );
        assertFalse(s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), address(harness)));
        assertFalse(s.timelock.hasRole(s.timelock.CANCELLER_ROLE(), address(harness)));
    }

    function test_roleTableIsExactlyAsIntended() public {
        BaseGovernanceDeploy.GovStack memory s = harness.deployStack(_params());

        assertTrue(s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), address(s.governor)), "governor proposes");
        assertTrue(s.timelock.hasRole(s.timelock.CANCELLER_ROLE(), address(s.governor)));
        assertTrue(s.timelock.hasRole(s.timelock.CANCELLER_ROLE(), guardian), "guardian vetoes");
        assertFalse(s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), guardian), "guardian must not propose");
        assertTrue(s.timelock.hasRole(s.timelock.EXECUTOR_ROLE(), address(0)), "execution open");
        assertTrue(s.timelock.hasRole(s.timelock.DEFAULT_ADMIN_ROLE(), address(s.timelock)), "self-admin");
    }

    function test_ownershipAndTokenWiring() public {
        BaseGovernanceDeploy.GovStack memory s = harness.deployStack(_params());

        assertEq(s.burner.owner(), address(s.timelock), "burner owner");
        assertEq(address(s.burner.GOV()), address(s.token), "burner points at the gov token");
        assertEq(address(s.governor.token()), address(s.token), "governor token");
        assertEq(s.governor.timelock(), address(s.timelock), "governor timelock");
        assertTrue(s.admin.hasRole(s.admin.DEFAULT_ADMIN_ROLE(), address(s.timelock)), "admin governed");
        assertTrue(s.admin.hasRole(s.admin.GUARDIAN_ROLE(), guardian));
        assertEq(s.admin.POOL(), address(masp));
        assertEq(s.admin.WRAPPER(), address(wrapper));
    }

    function test_tokenSupplyGoesEntirelyToTheRecipient() public {
        BaseGovernanceDeploy.GovStack memory s = harness.deployStack(_params());
        assertEq(s.token.totalSupply(), 1_000_000_000e18);
        assertEq(s.token.balanceOf(recipient), 1_000_000_000e18);
    }

    function test_governorParametersMatchConfig() public {
        BaseGovernanceDeploy.GovStack memory s = harness.deployStack(_params());
        assertEq(s.governor.votingDelay(), 2 days);
        assertEq(s.governor.votingPeriod(), 7 days);
        assertEq(s.governor.proposalThreshold(), 2_500_000e18);
        assertEq(s.governor.quorumNumerator(), 3);
        assertEq(s.timelock.getMinDelay(), 3 days);
    }

    /// The deploy does not touch the pool; handover is a separate step.
    function test_deployDoesNotTouchThePool() public {
        BaseGovernanceDeploy.GovStack memory s = harness.deployStack(_params());
        s;
        assertEq(masp.owner(), address(this), "deploy must not move ownership");
        assertEq(masp.treasury(), address(0xfee), "deploy must not repoint the treasury");
    }

    function test_revertsIfMaspHasNoCode() public {
        BaseGovernanceDeploy.GovParams memory p = _params();
        p.masp = makeAddr("notAPool");
        vm.expectRevert(bytes("masp has no code"));
        harness.deployStack(p);
    }

    function test_zeroGuardianDeploysWithoutOne() public {
        BaseGovernanceDeploy.GovParams memory p = _params();
        p.guardian = address(0);
        BaseGovernanceDeploy.GovStack memory s = harness.deployStack(p);

        assertFalse(s.timelock.hasRole(s.timelock.CANCELLER_ROLE(), address(0)));
        assertTrue(s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), address(s.governor)));
    }
}
