// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { Bundler } from "../../src/bundler/Bundler.sol";
import { BundlerFactory } from "../../src/bundler/BundlerFactory.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// `BundlerFactory`: deterministic, owner-bound Bundlers that can only be
/// created by the account they belong to.
contract BundlerFactoryTest is Test {
    BundlerFactory internal factory;
    address internal pool;
    address internal nativeAdapter;
    address internal swapWrapper;

    address internal constant RELAYER = address(0x5E1A7E5);
    address internal constant OPERATOR = address(0x0FE7A70);

    function setUp() public {
        pool = address(new MockERC20("p", "p", 18));
        nativeAdapter = address(new MockERC20("n", "n", 18));
        swapWrapper = address(new MockERC20("s", "s", 18));
        factory = new BundlerFactory(pool, nativeAdapter, swapWrapper);
    }

    function test_create_landsAtPredictedAddress() public {
        address predicted = factory.predict(RELAYER);
        assertEq(predicted.code.length, 0, "nothing deployed yet");

        vm.expectEmit(address(factory));
        emit BundlerCreated(RELAYER, predicted);
        Bundler b = _create(RELAYER);

        assertEq(address(b), predicted, "Bundler at the predicted address");
        assertGt(predicted.code.length, 0, "Bundler deployed");
    }

    /// `predict` is plain CREATE2 over the creation code and the constructor
    /// arguments, so anyone can reproduce it off-chain.
    function test_predict_isCreate2OverConstructorArgs() public view {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(Bundler).creationCode, abi.encode(RELAYER, pool, nativeAdapter, swapWrapper))
        );
        address expected = vm.computeCreate2Address(bytes32(uint256(uint160(RELAYER))), initCodeHash, address(factory));
        assertEq(factory.predict(RELAYER), expected, "CREATE2 address");
    }

    function test_create_setsOwnerOperatorsTargets() public {
        Bundler b = _create(RELAYER);

        assertEq(b.owner(), RELAYER, "caller owns the Bundler");
        assertTrue(b.isOperator(OPERATOR), "operator set");
        assertFalse(b.isOperator(RELAYER), "owner is not implicitly an operator");
        assertEq(b.POOL(), pool, "pool");
        assertEq(b.NATIVE_ADAPTER(), nativeAdapter, "native adapter");
        assertEq(b.SWAP_WRAPPER(), swapWrapper, "swap wrapper");
    }

    /// The operator list is handed over only for the duration of `create`, and
    /// does not change the address.
    function test_operators_doNotMoveTheAddress_andAreNotLeftPending() public {
        address predicted = factory.predict(RELAYER);
        address[] memory operators = new address[](3);
        operators[0] = address(0xA1);
        operators[1] = address(0xA2);
        operators[2] = address(0xA3);
        vm.prank(RELAYER);
        Bundler b = factory.create(operators);

        assertEq(address(b), predicted, "same address for any operator list");
        for (uint256 i; i < operators.length; ++i) {
            assertTrue(b.isOperator(operators[i]), "every operator set");
        }
        assertEq(factory.pendingOperators().length, 0, "nothing pending after create");
    }

    function test_create_noOperators() public {
        vm.prank(RELAYER);
        Bundler b = factory.create(new address[](0));
        assertFalse(b.isOperator(OPERATOR), "no operator");
        assertEq(b.owner(), RELAYER, "owner still set");
    }

    function test_create_zeroOperator_reverts() public {
        address[] memory operators = new address[](1);
        vm.expectRevert(Bundler.ZeroAddress.selector);
        vm.prank(RELAYER);
        factory.create(operators);
    }

    function test_create_twiceBySameOwner_reverts() public {
        Bundler first = _create(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(BundlerFactory.AlreadyCreated.selector, RELAYER, address(first)));
        vm.prank(RELAYER);
        factory.create(new address[](0));
    }

    function test_distinctOwners_distinctBundlers() public {
        Bundler a = _create(RELAYER);
        Bundler b = _create(address(0xB0B));
        assertTrue(address(a) != address(b), "one Bundler per owner");
    }

    /// A third party cannot take a relayer's advertised address: its `create`
    /// lands at its own predicted address, owned by itself.
    function test_thirdPartyCannotClaimAnotherRelayersAddress() public {
        address predicted = factory.predict(RELAYER);
        address squatter = address(0x5A7);

        Bundler taken = _create(squatter);

        assertTrue(address(taken) != predicted, "squatter lands elsewhere");
        assertEq(predicted.code.length, 0, "relayer's address still free");
        assertEq(address(_create(RELAYER)), predicted, "relayer still gets its address");
    }

    function test_create_isPermissionless() public {
        Bundler b = _create(address(0xAAAA));
        assertEq(b.owner(), address(0xAAAA), "any account may create its own");
    }

    function test_constructor_rejectsZeroPool() public {
        vm.expectRevert(BundlerFactory.ZeroAddress.selector);
        new BundlerFactory(address(0), nativeAdapter, swapWrapper);
    }

    /// Adapters may be zero; any non-zero address, including the pool, must be a
    /// contract.
    function test_constructor_adapters() public {
        BundlerFactory poolOnly = new BundlerFactory(pool, address(0), address(0));
        assertEq(poolOnly.NATIVE_ADAPTER(), address(0), "no native adapter");
        assertEq(poolOnly.SWAP_WRAPPER(), address(0), "no wrapper");

        vm.expectRevert(abi.encodeWithSelector(BundlerFactory.NotAContract.selector, address(0xC0DE)));
        new BundlerFactory(pool, address(0xC0DE), swapWrapper);
        vm.expectRevert(abi.encodeWithSelector(BundlerFactory.NotAContract.selector, address(0xC0DE)));
        new BundlerFactory(pool, nativeAdapter, address(0xC0DE));
        vm.expectRevert(abi.encodeWithSelector(BundlerFactory.NotAContract.selector, address(0xC0DE)));
        new BundlerFactory(address(0xC0DE), nativeAdapter, swapWrapper);
    }

    /// The Bundler reads its operators from its deployer, so it cannot be
    /// deployed from an account that does not provide them.
    function test_bundler_requiresADeployerWithOperators() public {
        vm.expectRevert();
        new Bundler(RELAYER, pool, nativeAdapter, swapWrapper);
    }

    event BundlerCreated(address indexed owner, address indexed bundler);

    function _create(address owner_) internal returns (Bundler) {
        address[] memory operators = new address[](1);
        operators[0] = OPERATOR;
        vm.prank(owner_);
        return factory.create(operators);
    }
}
