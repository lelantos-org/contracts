// Emit asset_registry.json fixture consumed by contracts/script/DeployTest.s.sol
// and contracts/test/MASP.deploy.t.sol. The asset generator is now derived
// in-circuit from publicAssetId via HashToAssetGen, so the registry no
// longer carries genX/genY.
import { writeFileSync, mkdirSync } from "fs";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

interface AssetSpec {
    id: number;
    symbol: string;
    name: string;
    decimals: number;
    scale: string;
}

// asset id 1 is wired to MockWETH9 by DeployTest.s.sol via the "WETH" symbol
// match; e2e multi-asset/eth-bridge tests rely on this. Other slots are
// plain MockERC20 instances.
// `scale` collapses base-units into circuit-units: publicIn = baseUnits / scale.
// publicIn must fit uint48 (max ≈ 2.81e14). For 18-decimal tokens scale=1
// breaks at ~0.000281 ETH. 1e10 leaves 8 fractional digits — plenty for UX
// and lets 1 ETH = 1e8 circuit units fit comfortably.
const SPECS: AssetSpec[] = [
    { id: 1, symbol: "WETH",  name: "Wrapped Ether", decimals: 18, scale: "10000000000" }, // 1e10
    { id: 2, symbol: "mDAI",  name: "Mock DAI",      decimals: 18, scale: "10000000000" }, // 1e10
    { id: 3, symbol: "mWBTC", name: "Mock WBTC",     decimals: 8,  scale: "1" },
];

const DEFAULT_OUT = resolve(__dirname, "..", "..", "test", "fixtures", "asset_registry.json");

async function main() {
    const ids: string[] = [];
    const scales: string[] = [];
    const names: string[] = [];
    const symbols: string[] = [];
    const decimals: string[] = [];

    for (const s of SPECS) {
        ids.push(s.id.toString());
        scales.push(s.scale);
        names.push(s.name);
        symbols.push(s.symbol);
        decimals.push(s.decimals.toString());
    }

    const out = resolve(process.env.ASSET_REGISTRY_OUT ?? DEFAULT_OUT);
    mkdirSync(dirname(out), { recursive: true });
    const payload = { ids, scales, names, symbols, decimals };
    writeFileSync(out, JSON.stringify(payload, null, 2) + "\n");
    console.log(`wrote ${ids.length} assets -> ${out}`);
}

main().catch(e => { console.error(e); process.exit(1); });
