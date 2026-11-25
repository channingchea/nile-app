// Time-limited GET links for objects in an S3-compatible bucket (Cloudflare R2
// for replays). AWS Signature V4 query signing with WebCrypto — no SDK.

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) =>
  [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const sha256 = async (s: string) =>
  hex(await crypto.subtle.digest("SHA-256", enc.encode(s)));
const hmac = async (key: BufferSource, msg: string) =>
  crypto.subtle.sign(
    "HMAC",
    await crypto.subtle.importKey(
      "raw",
      key,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    ),
    enc.encode(msg),
  );
// RFC 3986 encoding, as SigV4 requires (encodeURIComponent leaves !'()* alone).
const rfc3986 = (s: string) =>
  encodeURIComponent(s).replace(
    /[!'()*]/g,
    (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase(),
  );

export interface PresignOptions {
  region: string; // "auto" for R2
  accessKey: string;
  secretKey: string;
  expiresSeconds: number; // 1..604800
  now?: Date;
}

/** Signed GET URL for `objectUrl` (https://host/<path>), valid for `expiresSeconds`. */
export async function presignGet(
  objectUrl: string,
  o: PresignOptions,
): Promise<string> {
  const u = new URL(objectUrl);
  const stamp = (o.now ?? new Date()).toISOString().replace(
    /[-:]|\.\d{3}/g,
    "",
  ); // YYYYMMDDTHHMMSSZ
  const day = stamp.slice(0, 8);
  const scope = `${day}/${o.region}/s3/aws4_request`;
  const path = u.pathname.split("/").map((s) => rfc3986(decodeURIComponent(s)))
    .join("/");
  const params: [string, string][] = [
    ["X-Amz-Algorithm", "AWS4-HMAC-SHA256"],
    ["X-Amz-Credential", `${o.accessKey}/${scope}`],
    ["X-Amz-Date", stamp],
    ["X-Amz-Expires", String(o.expiresSeconds)],
    ["X-Amz-SignedHeaders", "host"],
  ];
  const query = params.map(([k, v]) => `${rfc3986(k)}=${rfc3986(v)}`).sort()
    .join("&");
  const request = [
    "GET",
    path,
    query,
    `host:${u.host}\n`,
    "host",
    "UNSIGNED-PAYLOAD",
  ].join("\n");
  const toSign = ["AWS4-HMAC-SHA256", stamp, scope, await sha256(request)].join(
    "\n",
  );
  let key: BufferSource = enc.encode("AWS4" + o.secretKey);
  for (const part of [day, o.region, "s3", "aws4_request"]) {
    key = await hmac(key, part);
  }
  const signature = hex(await hmac(key, toSign));
  return `${u.origin}${path}?${query}&X-Amz-Signature=${signature}`;
}
