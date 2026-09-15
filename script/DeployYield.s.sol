// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { MASP } from "../src/MASP.sol";
import { ERC4626Venue } from "../src/yield/ERC4626Venue.sol";

/// Yield-asset deploy against an already-deployed MASP: one `ERC4626Venue` per
/// asset, then the owner registration that binds it.
///
/// Separate from `Deploy.s.sol` and reading its own `{chain}.yield.json`, in the
/// same way `DeploySwap.s.sol` reads `{chain}.swap.json`. `DeployConfig.t.sol`
/// pins the core chain configs' shape against an explicit file list.
///
/// `ERC4626Venue` is caller-pinned to the pool, so it can only be deployed once
/// the pool exists; a yield asset is therefore registered here rather than in
/// the initialization arrays. Registration is permanent: `MASP.addYieldAsset`
/// goes through the add-only registry, so an id's venue cannot be re-pointed
/// and there is no `setVenue`. A wrong vault requires retiring the id and
/// registering a new one.
///
/// A yield id is registered alongside the token's existing plain id, not in
/// place of it. The two differ only in the venue binding, which is how a
/// depositor chooses custody or yield.
///
/// Config schema:
///   {
///     "masp":   "0x...",              required, must have code
///     "assets": [
///       { "id":          9,           new id, must not already be registered
///         "token":       "0x...",     must match the plain id's token
///         "scale":       "1",         must match the plain id's scale
///         "vault":       "0x...",     ERC-4626; asset() is checked on-chain
///         "depositBps":  20,
///         "withdrawBps": 20,
///         "bufferBps":   500,         share kept unlent for withdrawals
///         "perfBps":     1000 }       performance fee on yield
///     ]
///   }
///
/// Run: `YIELD_CONFIG=script/config/base.yield.json \
///       forge script script/DeployYield.s.sol --rpc-url $RPC --broadcast`
///
/// Must be broadcast by the pool's owner: `addYieldAsset` is `onlyOwner`.
///
/// Runbook, after this script: seed each new id before announcing it. A fresh
/// id has no minimum liquidity, so its first and only holder can donate vault
/// shares to the venue and inflate the index until one unit costs about 1e24
/// wei; units are `uint48`, so the id becomes unusable at normal sizes. The
/// donation accrues to whoever holds units, so it is griefing only, and it stops
/// paying once someone else holds a meaningful share. The operator therefore
/// shields a seed deposit into the id (for example 1,000 units) into a note held
/// by the treasury, through the SDK, and waits for it to be flushed; a donation
/// then mostly enriches the seed's holder. The seed is not scripted here: a flushable
/// deposit needs a note commitment, a Pedersen value commitment that the
/// tree-update circuit binds to the amount, and encrypted payloads, all built
/// off-chain by the wallet. A placeholder deposit with a dummy commitment could
/// never be flushed, and relayers would have to learn to skip it.
contract DeployYield is Script {
    string constant DEFAULT_CONFIG = "script/config/mainnet.yield.json";

    struct YieldAsset {
        uint16 bufferBps;
        uint16 depositBps;
        uint64 id;
        uint16 perfBps;
        uint256 scale;
        address token;
        address vault;
        uint16 withdrawBps;
    }

    function run() external returns (address[] memory venues) {
        string memory path = vm.envOr("YIELD_CONFIG", DEFAULT_CONFIG);
        string memory j = vm.readFile(path);

        address maspAddr = vm.parseJsonAddress(j, ".masp");
        _requireCode(maspAddr, "MASP has no code");
        MASP masp = MASP(maspAddr);

        // `parseJson` orders struct fields alphabetically; `YieldAsset` above is
        // declared in that order so the decode lines up.
        YieldAsset[] memory assets = abi.decode(vm.parseJson(j, ".assets"), (YieldAsset[]));
        require(assets.length != 0, "no yield assets configured");

        venues = new address[](assets.length);

        for (uint256 i; i < assets.length; ++i) {
            YieldAsset memory a = assets[i];
            _preflight(masp, a);

            vm.startBroadcast();
            ERC4626Venue venue = new ERC4626Venue(maspAddr, a.vault, a.token);
            masp.addYieldAsset(
                a.id, IERC20(a.token), a.scale, a.depositBps, a.withdrawBps, address(venue), a.bufferBps, a.perfBps
            );
            vm.stopBroadcast();

            venues[i] = address(venue);
            console2.log("yieldAsset.id", a.id);
            console2.log("yieldAsset.venue", address(venue));
            console2.log("yieldAsset.vault", a.vault);
        }
    }

    /// Everything that must hold before a permanent binding is broadcast.
    ///
    /// The vault's asset is read from the vault itself rather than trusted from
    /// the config, so a mistyped vault address cannot bind an asset id
    /// permanently to the wrong vault.
    function _preflight(MASP masp, YieldAsset memory a) internal view {
        _requireCode(a.token, "token has no code");
        _requireCode(a.vault, "vault has no code");
        require(a.vault != address(0), "vault zero");
        require(a.scale != 0, "scale zero");
        require(a.bufferBps <= 10_000, "bufferBps over 100%");
        require(a.perfBps <= 2_000, "perfBps over MAX_FEE_BPS");

        require(IERC4626(a.vault).asset() == a.token, "vault asset does not match token");

        // The id must be free. `addYieldAsset` would also revert; checking here
        // costs no gas and gives a descriptive error.
        try masp.asset(a.id) returns (MASP.AssetEntry memory) {
            revert("asset id already registered");
        } catch { }
    }

    function _requireCode(address addr, string memory label) internal view {
        require(addr.code.length != 0, label);
    }
}
