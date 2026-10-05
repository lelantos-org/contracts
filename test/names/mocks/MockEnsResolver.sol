// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// A plain (non-wildcard) resolver holding one address record, standing in for
/// the resolver a parent name had before the wildcard one.
contract MockEnsResolver {
    error NoRecord();

    mapping(bytes32 node => address) public addr;

    function setAddr(bytes32 node, address a) external {
        addr[node] = a;
    }

    function fail(bytes32) external pure {
        revert NoRecord();
    }
}
