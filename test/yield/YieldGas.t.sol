// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { console2 } from "forge-std/console2.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { YieldBase } from "./YieldBase.t.sol";

/// Plain vs indexed cost on the two hot paths. Prints rather than asserts.
contract YieldGasTest is YieldBase {
    uint64 internal constant N = 1_000_000;

    function _depositGas(uint64 id, uint256 seed) internal returns (uint256 used) {
        token.mint(payer, type(uint128).max);
        _allow(type(uint160).max);
        PubInputs.DepositRequest memory d = _request(id, N, 0, seed);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        vm.prank(payer);
        uint256 g0 = gasleft();
        masp.depositAuthorized(d, aux[0], aux[1]);
        used = g0 - gasleft();
    }

    function _withdrawGas(uint64 id, uint256 seed, uint64 outUnits) internal returns (uint256 used) {
        PubInputs.Transact memory pi;
        pi.chainId = block.chainid;
        pi.publicAssetId = id;
        pi.publicOut = outUnits;
        pi.recipient = RECIPIENT;
        pi.payer = SPEND_PAYER;
        pi.relayer = RELAYER;
        SpendFixture.fillOutputs(pi, seed, seed + 0x1000);
        pi.merkleRoot = masp.currentRoot();
        PubInputs.TreeUpdateBatch memory tpi =
            SpendFixture.batchFor(pi, masp.currentRoot(), bytes32(seed + 0x20000), masp.committedCount());
        vm.prank(RELAYER);
        uint256 g0 = gasleft();
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
        used = g0 - gasleft();
    }

    function test_gas_depositAndWithdraw() public {
        // Warm-up pass on both sides first: the recipient balance, the token
        // slots and the venue address are all cold on their first touch, and
        // comparing a cold path against a warm one measures nothing.
        _depositGas(PLAIN_ID, 0x201);
        _depositGas(YIELD_ID, 0x101);
        _withdrawGas(PLAIN_ID, 0x3001, N / 8);
        _withdrawGas(YIELD_ID, 0x4001, N / 8);

        uint256 plainDep = _depositGas(PLAIN_ID, 0x221);
        uint256 yieldDep = _depositGas(YIELD_ID, 0x121);

        // Large exit: more than the buffer, so the venue must be drawn on.
        uint256 plainBig = _withdrawGas(PLAIN_ID, 0x5001, N / 8);
        uint256 yieldBig = _withdrawGas(YIELD_ID, 0x6001, N / 8);
        // Small exit: the buffer covers it and the venue is never touched.
        // That is what the buffer is for, and the common case in production.
        uint256 plainSmall = _withdrawGas(PLAIN_ID, 0x7001, 1_000);
        uint256 yieldSmall = _withdrawGas(YIELD_ID, 0x8001, 1_000);

        console2.log("dep_plain", plainDep);
        console2.log("dep_yield", yieldDep);
        console2.log("wd_plain_big", plainBig);
        console2.log("wd_yield_big", yieldBig);
        console2.log("wd_plain_small", plainSmall);
        console2.log("wd_yield_small", yieldSmall);
        console2.logInt(int256(yieldDep) - int256(plainDep));
        console2.logInt(int256(yieldBig) - int256(plainBig));
        console2.logInt(int256(yieldSmall) - int256(plainSmall));

        // Loose ceilings, as a regression guard rather than a pin. The premium
        // an indexed asset pays over a plain one is what the optimisation work
        // targeted: funding the venue only across a band, and refilling the
        // buffer on a draw. A change that reintroduces a per-deposit vault mint
        // or an empty buffer blows through these by a wide margin.
        assertLt(yieldDep - plainDep, 55_000, "shield premium regressed");
        assertLt(yieldBig - plainBig, 30_000, "buffer-exceeding exit premium regressed");
        assertLt(yieldSmall - plainSmall, 15_000, "buffer-served exit premium regressed");
    }
}
