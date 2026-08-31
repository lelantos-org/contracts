// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../src/MASP.sol";
import { ERC4626Venue } from "../src/yield/ERC4626Venue.sol";
import { MockERC4626 } from "../test/mocks/MockERC4626.sol";

/// Test/anvil yield stack: one `MockERC4626` vault plus its `ERC4626Venue` per
/// registered asset, then the owner registration that binds each as a *new*
/// yield asset id. Run after `DeployTest.s.sol`, whose KEY=value output
/// supplies the env vars below.
///
/// Separate from `DeployYield.s.sol`, which registers venues from a
/// `{chain}.yield.json` naming vaults that already exist on a real chain. A
/// local stack has no such vault, and the vault addresses only exist once this
/// script has deployed them, so there is nothing a config file could name —
/// this is the same split as `Deploy.s.sol` / `DeployTest.s.sol`.
///
/// A yield id is registered *alongside* the token's plain id, never in place of
/// it: the plain id stays risk-free custody and the yield id earns, and a
/// depositor opts in by choosing an id. Ids come from the same committed
/// fixture as the plain ones, shifted by `YIELD_ID_OFFSET` (default: the asset
/// count, so 1,2,3 -> 4,5,6). Scale is copied from the plain id, as the two
/// differ only in the venue binding.
///
/// Registration is permanent — `addYieldAsset` goes through the add-only
/// registry — so a re-run against the same MASP reverts on the first id. That
/// is intended: `just redeploy` re-runs `DeployTest.s.sol` too, which yields a
/// fresh MASP with none of these ids taken.
///
/// Required env (populated from DeployTest output):
///   MASP                       — MASP address, owned by the broadcasting key
///   TOKEN_1, TOKEN_2, TOKEN_3  — registered token addresses (fixture ids)
///
/// Optional:
///   YIELD_ID_OFFSET      plain id -> yield id shift  (default: asset count)
///   YIELD_BUFFER_BPS     share kept unlent           (default 500 = 5%)
///   YIELD_PERF_BPS       performance fee on yield    (default 1000 = 10%)
///   MASP_DEPOSIT_BPS     deposit fee                 (default 25, as DeployTest)
///   MASP_WITHDRAW_BPS    withdraw fee                (default 25, as DeployTest)
contract DeployTestYield is Script {
    string constant REGISTRY_FIXTURE = "test/fixtures/asset_registry.json";

    /// Grouped so the per-asset loop stays clear of the stack-depth limit.
    struct Params {
        uint16 depositBps;
        uint16 withdrawBps;
        uint16 bufferBps;
        uint16 perfBps;
    }

    function run() external returns (address[] memory venues, address[] memory vaults) {
        address maspAddr = vm.envAddress("MASP");
        _requireCode(maspAddr, "MASP has no code");
        MASP masp = MASP(maspAddr);

        string memory j = vm.readFile(REGISTRY_FIXTURE);
        uint256[] memory rawIds = vm.parseJsonUintArray(j, ".ids");
        uint256[] memory scales = vm.parseJsonUintArray(j, ".scales");
        uint256 n = rawIds.length;
        require(scales.length == n, "registry length mismatch");

        // Shifting by the asset count keeps every yield id clear of every plain
        // one for this fixture. An offset small enough to overlap would collide
        // on `addYieldAsset`, which is caught below rather than mid-broadcast.
        uint64 offset = uint64(vm.envOr("YIELD_ID_OFFSET", n));
        require(offset >= n, "YIELD_ID_OFFSET overlaps the plain ids");

        Params memory q = Params({
            depositBps: uint16(vm.envOr("MASP_DEPOSIT_BPS", uint256(25))),
            withdrawBps: uint16(vm.envOr("MASP_WITHDRAW_BPS", uint256(25))),
            bufferBps: uint16(vm.envOr("YIELD_BUFFER_BPS", uint256(500))),
            perfBps: uint16(vm.envOr("YIELD_PERF_BPS", uint256(1000)))
        });

        venues = new address[](n);
        vaults = new address[](n);

        for (uint256 i; i < n; ++i) {
            uint64 plainId = uint64(rawIds[i]);
            uint64 yieldId = plainId + offset;
            // Fixture order and `TOKEN_<id>` are the same table DeployTest
            // logged, so the token is read by id rather than by position.
            address token = vm.envAddress(string.concat("TOKEN_", vm.toString(uint256(plainId))));
            _preflight(masp, yieldId, token, scales[i]);

            vm.startBroadcast();
            // The venue is caller-pinned to the pool, so it cannot exist before
            // the pool's constructor has run — which is why a yield asset is
            // registered here rather than in DeployTest's constructor arrays.
            MockERC4626 vault = new MockERC4626(IERC20(token));
            ERC4626Venue venue = new ERC4626Venue(address(masp), address(vault), token);
            masp.addYieldAsset(
                yieldId, IERC20(token), scales[i], q.depositBps, q.withdrawBps, address(venue), q.bufferBps, q.perfBps
            );
            vm.stopBroadcast();

            vaults[i] = address(vault);
            venues[i] = address(venue);

            // KEY=value block scraped by backend/stack/scripts/deploy-contracts.sh
            // and e2e. The id is in the key, as `TOKEN_<id>` already is, so the
            // address table alone says which plain asset each pair belongs to.
            console2.log(string.concat("YIELD_TOKEN_", vm.toString(uint256(yieldId)), "=", vm.toString(token)));
            console2.log(string.concat("YIELD_VAULT_", vm.toString(uint256(yieldId)), "=", vm.toString(vaults[i])));
            console2.log(string.concat("YIELD_VENUE_", vm.toString(uint256(yieldId)), "=", vm.toString(venues[i])));
        }
    }

    /// Everything that must hold before a permanent binding is broadcast.
    function _preflight(MASP masp, uint64 yieldId, address token, uint256 scale) internal view {
        _requireCode(token, "token has no code");
        require(scale != 0, "scale zero");
        // `addYieldAsset` is `onlyOwner`; failing here names the problem
        // instead of reverting inside the broadcast with `OwnableUnauthorized`.
        require(masp.owner() == tx.origin, "broadcasting key does not own the MASP");

        // The id must be free. `addYieldAsset` would revert anyway; failing
        // here costs no gas and names the id.
        try masp.asset(yieldId) returns (MASP.AssetEntry memory) {
            revert("yield asset id already registered");
        } catch { }
    }

    function _requireCode(address addr, string memory label) internal view {
        require(addr.code.length != 0, label);
    }
}
