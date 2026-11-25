// Apple IAP verification (_shared/apple_iap.ts), Phase 2.
//
//   deno test --allow-env supabase/functions/tests/apple_iap_test.ts
//
// Builds a throwaway three-certificate chain shaped like Apple's (same marker
// extensions), signs JWS with it, and checks the verifier accepts exactly the
// genuine ones. The DB side (replayed transaction, refund, duplicate) is checked
// by the rolled-back SQL selftest in migration 0157's notes.

import "npm:reflect-metadata@0.2.2";
import * as x509 from "npm:@peculiar/x509@3.1.0";
import { assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  AppleIapError, type AppleTransaction, checkTransaction, INTERMEDIATE_OID, ladderCents,
  LEAF_OID, productIdFor, verifyAppleJws,
} from "../_shared/apple_iap.ts";

const ALG = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" };
const gen = () => crypto.subtle.generateKey(ALG, true, ["sign", "verify"]) as Promise<CryptoKeyPair>;
const marker = (oid: string) => new x509.Extension(oid, false, new Uint8Array([5, 0]));
const from = new Date("2020-01-01"), to = new Date("2040-01-01");

async function chain(opts: { leafMarker?: boolean } = {}) {
  const rootK = await gen(), intK = await gen(), leafK = await gen();
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    name: "CN=Test Root", keys: rootK, signingAlgorithm: ALG, notBefore: from, notAfter: to,
    extensions: [new x509.BasicConstraintsExtension(true, 2, true)],
  });
  const inter = await x509.X509CertificateGenerator.create({
    subject: "CN=Test Intermediate", issuer: root.subject, publicKey: intK.publicKey,
    signingKey: rootK.privateKey, signingAlgorithm: ALG, notBefore: from, notAfter: to,
    extensions: [marker(INTERMEDIATE_OID), new x509.BasicConstraintsExtension(true, 0, true)],
  });
  const leaf = await x509.X509CertificateGenerator.create({
    subject: "CN=Test Leaf", issuer: inter.subject, publicKey: leafK.publicKey,
    signingKey: intK.privateKey, signingAlgorithm: ALG, notBefore: from, notAfter: to,
    extensions: opts.leafMarker === false ? [] : [marker(LEAF_OID)],
  });
  const der = (c: x509.X509Certificate) => new Uint8Array(c.rawData);
  return { root: der(root), x5c: [leaf, inter, root].map((c) => c.toString("base64")), key: leafK.privateKey };
}

const enc = (o: unknown) =>
  btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(o))))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function sign(c: Awaited<ReturnType<typeof chain>>, payload: unknown) {
  const input = `${enc({ alg: "ES256", x5c: c.x5c })}.${enc(payload)}`;
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, c.key, new TextEncoder().encode(input)),
  );
  return `${input}.${btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")}`;
}

const TICKET = "6f1c2b3a-1d2e-4f50-8a9b-0c1d2e3f4a5b";
const tx = (over: Partial<AppleTransaction> = {}): AppleTransaction => ({
  transactionId: "2000000123456789",
  originalTransactionId: "2000000123456789",
  bundleId: "com.nilestreaming.app",
  productId: "com.nilestreaming.app.ppv.1499",
  appAccountToken: TICKET.toUpperCase(),
  environment: "Production",
  type: "Consumable",
  signedDate: Date.parse("2026-11-24T12:00:00Z"),
  ...over,
});

Deno.test("a genuine signed transaction verifies and settles", async () => {
  const c = await chain();
  const out = await verifyAppleJws<AppleTransaction>(await sign(c, tx()), [c.root]);
  assertEquals(checkTransaction(out), { ticketId: TICKET, storeCents: 1499, environment: "Production" });
});

Deno.test("bad signature: payload edited after signing", async () => {
  const c = await chain();
  const [h, , s] = (await sign(c, tx())).split(".");
  const forged = `${h}.${enc(tx({ productId: "com.nilestreaming.app.ppv.9999" }))}.${s}`;
  await assertRejects(() => verifyAppleJws(forged, [c.root]), AppleIapError, "bad_signature");
});

Deno.test("a chain that isn't Apple's root is refused", async () => {
  const c = await chain();
  // Default trust = the real Apple Root CA - G3 only.
  await assertRejects(async () => verifyAppleJws(await sign(c, tx())), AppleIapError, "untrusted_root");
});

Deno.test("a leaf without Apple's marker is refused", async () => {
  const c = await chain({ leafMarker: false });
  await assertRejects(async () => verifyAppleJws(await sign(c, tx()), [c.root]), AppleIapError, "not_apple_chain");
});

Deno.test("garbage is refused, not thrown as a 500", async () => {
  await assertRejects(() => verifyAppleJws("nope"), AppleIapError, "malformed_jws");
  await assertRejects(() => verifyAppleJws(undefined as unknown as string), AppleIapError, "malformed_jws");
});

Deno.test("wrong product, bundle or account token is refused", () => {
  assertThrows(() => checkTransaction(tx({ productId: "com.nilestreaming.app.ppv.1500" })), AppleIapError, "wrong_product");
  assertThrows(() => checkTransaction(tx({ productId: "com.other.app.ppv.1499" })), AppleIapError, "wrong_product");
  assertThrows(() => checkTransaction(tx({ type: "Auto-Renewable Subscription" })), AppleIapError, "wrong_product");
  assertThrows(() => checkTransaction(tx({ bundleId: "com.other.app" })), AppleIapError, "wrong_bundle");
  assertThrows(() => checkTransaction(tx({ appAccountToken: undefined })), AppleIapError, "no_ticket");
  assertThrows(() => checkTransaction(tx({ revocationDate: 1 })), AppleIapError, "revoked");
  assertThrows(() => checkTransaction(tx({ environment: "Xcode" })), AppleIapError, "wrong_environment");
});

Deno.test("sandbox purchases settle but are marked Sandbox (never paid out)", () => {
  assertEquals(checkTransaction(tx({ environment: "Sandbox" })).environment, "Sandbox");
});

Deno.test("ladder ids", () => {
  assertEquals(ladderCents("com.nilestreaming.app.ppv.0199"), 199);
  assertEquals(ladderCents("com.nilestreaming.app.ppv.9999"), 9999);
  assertEquals(ladderCents("com.nilestreaming.app.ppv.0099"), null);
  assertEquals(productIdFor(499), "com.nilestreaming.app.ppv.0499");
});
