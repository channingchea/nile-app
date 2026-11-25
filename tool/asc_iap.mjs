#!/usr/bin/env node
// App Store Connect helper for Nile's in-app purchase price ladder.
// Uses the existing ASC API key (no dependencies).
//
//   node tool/asc_iap.mjs list                 # products already in App Store Connect
//   node tool/asc_iap.mjs ladder [--dry]       # create any missing .ppv.0199 … .ppv.9999
//   node tool/asc_iap.mjs screenshot <png>     # attach one review screenshot to every product
//   node tool/asc_iap.mjs get <path>           # raw GET, e.g. /v1/apps/6795326948
//
// Env overrides: ASC_KEY_ID, ASC_ISSUER, ASC_KEY_PATH, ASC_APP_ID.
import { createHash, createPrivateKey, sign } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename } from "node:path";

const KEY_ID = process.env.ASC_KEY_ID ?? "QPG32KNFL8";
const ISSUER = process.env.ASC_ISSUER ?? "b7187ac6-2b39-4787-afe9-ab77f39676d1";
const KEY_PATH = process.env.ASC_KEY_PATH ??
  `${homedir()}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`;
const APP_ID = process.env.ASC_APP_ID ?? "6795326948";
const BUNDLE = "com.nilestreaming.app";
const API = "https://api.appstoreconnect.apple.com";

// The ladder: $1.99 … $99.99, one consumable per whole dollar.
export const LADDER = Array.from({ length: 99 }, (_, i) => (i + 2) * 100 - 1);
export const productId = (cents) => `${BUNDLE}.ppv.${String(cents).padStart(4, "0")}`;
const dollars = (cents) => `$${(cents / 100).toFixed(2)}`;

const b64url = (b) => Buffer.from(b).toString("base64url");
function token() {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "ES256", kid: KEY_ID, typ: "JWT" }));
  const body = b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 1100, aud: "appstoreconnect-v1" }));
  const sig = sign("sha256", Buffer.from(`${head}.${body}`), {
    key: createPrivateKey(readFileSync(KEY_PATH)),
    dsaEncoding: "ieee-p1363",
  });
  return `${head}.${body}.${b64url(sig)}`;
}

async function asc(method, path, body) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(path.startsWith("http") ? path : API + path, {
      method,
      headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.status === 429 && attempt < 5) {
      await new Promise((r) => setTimeout(r, 5000 * (attempt + 1)));
      continue;
    }
    const text = await res.text();
    const json = text ? JSON.parse(text) : {};
    if (!res.ok) {
      const err = new Error(`${method} ${path} → ${res.status}: ${JSON.stringify(json.errors ?? json)}`);
      err.status = res.status;
      throw err;
    }
    return json;
  }
}

async function all(path) {
  const out = [];
  for (let next = path; next; ) {
    const page = await asc("GET", next);
    out.push(...page.data);
    next = page.links?.next;
  }
  return out;
}

const existing = async () =>
  new Map((await all(`/v1/apps/${APP_ID}/inAppPurchasesV2?limit=200`))
    .map((p) => [p.attributes.productId, p]));

async function createOne(cents, territories) {
  const name = `Show access – ${dollars(cents)}`;
  const iap = (await asc("POST", "/v2/inAppPurchases", {
    data: {
      type: "inAppPurchases",
      attributes: {
        name,
        productId: productId(cents),
        inAppPurchaseType: "CONSUMABLE",
        reviewNote:
          "Unlocks one ticketed livestream or replay on Nile. The in-app price is set by the show's ticket price; " +
          "each price point is one product. Purchased from the event page.",
      },
      relationships: { app: { data: { type: "apps", id: APP_ID } } },
    },
  })).data;

  await asc("POST", "/v1/inAppPurchaseLocalizations", {
    data: {
      type: "inAppPurchaseLocalizations",
      attributes: { locale: "en-US", name: `Show access ${dollars(cents)}`, description: "Access to one show or replay on Nile." },
      relationships: { inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap.id } } },
    },
  });

  const points = await all(`/v2/inAppPurchases/${iap.id}/pricePoints?filter[territory]=USA&limit=8000`);
  const point = points.find((p) => Math.round(Number(p.attributes.customerPrice) * 100) === cents);
  if (!point) throw new Error(`no USA price point for ${dollars(cents)}`);
  await asc("POST", "/v1/inAppPurchasePriceSchedules", {
    data: {
      type: "inAppPurchasePriceSchedules",
      relationships: {
        inAppPurchase: { data: { type: "inAppPurchases", id: iap.id } },
        baseTerritory: { data: { type: "territories", id: "USA" } },
        manualPrices: { data: [{ type: "inAppPurchasePrices", id: "${p0}" }] },
      },
    },
    included: [{
      type: "inAppPurchasePrices",
      id: "${p0}",
      attributes: { startDate: null },
      relationships: { inAppPurchasePricePoint: { data: { type: "inAppPurchasePricePoints", id: point.id } } },
    }],
  });

  await asc("POST", "/v1/inAppPurchaseAvailabilities", {
    data: {
      type: "inAppPurchaseAvailabilities",
      attributes: { availableInNewTerritories: true },
      relationships: {
        inAppPurchase: { data: { type: "inAppPurchases", id: iap.id } },
        availableTerritories: { data: territories.map((id) => ({ type: "territories", id })) },
      },
    },
  });
  return iap;
}

async function ladder(dry) {
  const have = await existing();
  const missing = LADDER.filter((c) => !have.has(productId(c)))
    .slice(0, Number(process.env.LIMIT ?? LADDER.length));
  console.log(`${have.size} products exist, ${missing.length} to create`);
  if (dry || !missing.length) return;
  const territories = (await all("/v1/territories?limit=200")).map((t) => t.id);
  for (const cents of missing) {
    try {
      const iap = await createOne(cents, territories);
      console.log(`created ${productId(cents)} (${iap.id})`);
    } catch (e) {
      // Stop at the first failure: a half-made product needs a look, and the
      // same problem (agreement, role, price point) would hit every other one.
      console.error(`FAILED ${productId(cents)}: ${e.message}`);
      process.exit(1);
    }
  }
}

async function screenshot(file) {
  const bytes = readFileSync(file);
  const md5 = createHash("md5").update(bytes).digest("hex");
  for (const [pid, iap] of await existing()) {
    if (!pid.startsWith(`${BUNDLE}.ppv.`)) continue;
    const cur = await asc("GET", `/v2/inAppPurchases/${iap.id}/appStoreReviewScreenshot`).catch(() => null);
    if (cur?.data) continue;
    const shot = (await asc("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots", {
      data: {
        type: "inAppPurchaseAppStoreReviewScreenshots",
        attributes: { fileName: basename(file), fileSize: statSync(file).size },
        relationships: { inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap.id } } },
      },
    })).data;
    for (const op of shot.attributes.uploadOperations) {
      await fetch(op.url, {
        method: op.method,
        headers: Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value])),
        body: bytes.subarray(op.offset, op.offset + op.length),
      });
    }
    await asc("PATCH", `/v1/inAppPurchaseAppStoreReviewScreenshots/${shot.id}`, {
      data: { type: "inAppPurchaseAppStoreReviewScreenshots", id: shot.id, attributes: { uploaded: true, sourceFileChecksum: md5 } },
    });
    console.log(`screenshot → ${pid}`);
  }
}

const [cmd, arg] = process.argv.slice(2);
try {
  if (cmd === "list") {
    for (const [pid, p] of await existing()) console.log(pid, p.attributes.state, p.id);
  } else if (cmd === "ladder") await ladder(arg === "--dry");
  else if (cmd === "screenshot") await screenshot(arg);
  else if (cmd === "get") console.log(JSON.stringify(await asc("GET", arg), null, 2));
  else console.log("usage: list | ladder [--dry] | screenshot <png> | get <path>");
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
