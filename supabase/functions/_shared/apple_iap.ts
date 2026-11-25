// Apple in-app purchases: verifying Apple's signed transactions and server
// notifications (docs/plans/apple-iap-tickets.md, Phase 2).
//
// Apple signs every transaction and notification as a JWS whose header carries
// a three-certificate chain (x5c). It is genuine when:
//   1. the chain's root is byte-for-byte Apple Root CA - G3,
//   2. each certificate is signed by the next and valid at the signing date,
//   3. the leaf and intermediate carry Apple's marker extensions,
//   4. the JWS signature checks out against the leaf's key (ES256).
// This is what Apple's App Store Server Library does, minus its optional
// online revocation check.

import "npm:reflect-metadata@0.2.2";
import * as x509 from "npm:@peculiar/x509@3.1.0";

export const BUNDLE_ID = "com.nilestreaming.app";

// https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
// SHA-256 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
export const APPLE_ROOT_CA_G3 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";

export const LEAF_OID = "1.2.840.113635.100.6.11.1";
export const INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1";

export class AppleIapError extends Error {}

const b64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const b64url = (s: string) =>
  b64(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
const sameBytes = (a: Uint8Array, b: Uint8Array) =>
  a.length === b.length && a.every((v, i) => v === b[i]);

/** Verify an Apple JWS and return its payload. `roots` is for tests only. */
export async function verifyAppleJws<T = Record<string, unknown>>(
  jws: string,
  roots: Uint8Array[] = [b64(APPLE_ROOT_CA_G3)],
): Promise<T> {
  const parts = typeof jws === "string" ? jws.split(".") : [];
  if (parts.length !== 3) throw new AppleIapError("malformed_jws");
  let header: { alg?: string; x5c?: string[] };
  let payload: Record<string, unknown>;
  try {
    header = JSON.parse(new TextDecoder().decode(b64url(parts[0])));
    payload = JSON.parse(new TextDecoder().decode(b64url(parts[1])));
  } catch (_) {
    throw new AppleIapError("malformed_jws");
  }
  if (header.alg !== "ES256" || header.x5c?.length !== 3) {
    throw new AppleIapError("bad_header");
  }

  const [leaf, inter, root] = header.x5c.map((c) => new x509.X509Certificate(b64(c)));
  if (!roots.some((r) => sameBytes(new Uint8Array(root.rawData), r))) {
    throw new AppleIapError("untrusted_root");
  }
  if (!leaf.getExtension(LEAF_OID) || !inter.getExtension(INTERMEDIATE_OID)) {
    throw new AppleIapError("not_apple_chain");
  }
  // Valid when signed, the way Apple's library checks without online lookups.
  const signed = Number(payload.signedDate);
  const date = Number.isFinite(signed) && signed > 0 ? new Date(signed) : new Date();
  if (
    !(await inter.verify({ publicKey: root.publicKey, date })) ||
    !(await leaf.verify({ publicKey: inter.publicKey, date }))
  ) {
    throw new AppleIapError("bad_chain");
  }

  const key = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"]);
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    b64url(parts[2]),
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!ok) throw new AppleIapError("bad_signature");
  return payload as T;
}

/** The fields of Apple's JWSTransactionDecodedPayload that Nile uses. */
export interface AppleTransaction {
  transactionId: string;
  originalTransactionId?: string;
  bundleId: string;
  productId: string;
  appAccountToken?: string;
  environment: "Production" | "Sandbox" | string;
  type?: string;
  revocationDate?: number;
  signedDate?: number;
}

const PRODUCT = new RegExp(`^${BUNDLE_ID.replace(/\./g, "\\.")}\\.ppv\\.(\\d{4})$`);

/** Price in cents of a ladder product (`….ppv.1499` → 1499), or null. */
export function ladderCents(productId: string): number | null {
  const m = PRODUCT.exec(productId ?? "");
  if (!m) return null;
  const cents = Number(m[1]);
  return cents >= 199 && cents <= 9999 && cents % 100 === 99 ? cents : null;
}

/** App Store product for an iPhone price. Keep in step with PricingConfig.iapProductId. */
export const productIdFor = (cents: number) => `${BUNDLE_ID}.ppv.${String(cents).padStart(4, "0")}`;

/**
 * Checks a verified transaction is a Nile show purchase and returns what the
 * server needs to settle it. Throws AppleIapError with a short code otherwise.
 */
export function checkTransaction(tx: AppleTransaction): {
  ticketId: string;
  storeCents: number;
  environment: "Production" | "Sandbox";
} {
  if (tx.bundleId !== BUNDLE_ID) throw new AppleIapError("wrong_bundle");
  if (tx.environment !== "Production" && tx.environment !== "Sandbox") {
    throw new AppleIapError("wrong_environment");
  }
  const storeCents = ladderCents(tx.productId);
  if (storeCents === null) throw new AppleIapError("wrong_product");
  if (tx.type && tx.type !== "Consumable") throw new AppleIapError("wrong_product");
  if (tx.revocationDate) throw new AppleIapError("revoked");
  const ticketId = (tx.appAccountToken ?? "").toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(ticketId)) {
    throw new AppleIapError("no_ticket");
  }
  if (!tx.transactionId) throw new AppleIapError("malformed_jws");
  return { ticketId, storeCents, environment: tx.environment };
}
