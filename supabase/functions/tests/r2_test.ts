// Replay links on R2: SigV4 query signing (_shared/r2.ts).
//
//   deno test --allow-env supabase/functions/tests/

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { presignGet } from "../_shared/r2.ts";

Deno.test("matches AWS's published presigned-URL example", async () => {
  // https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
  const url = await presignGet(
    "https://examplebucket.s3.amazonaws.com/test.txt",
    {
      region: "us-east-1",
      accessKey: "AKIAIOSFODNN7EXAMPLE",
      secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      expiresSeconds: 86400,
      now: new Date("2013-05-24T00:00:00Z"),
    },
  );
  assertEquals(
    new URL(url).searchParams.get("X-Amz-Signature"),
    "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
  );
});

Deno.test("path-style R2 links keep the bucket and key", async () => {
  const url = new URL(
    await presignGet(
      "https://acct.r2.cloudflarestorage.com/nile-replays/ev/1.mp4",
      {
        region: "auto",
        accessKey: "k",
        secretKey: "s",
        expiresSeconds: 600,
        now: new Date("2026-11-24T00:00:00Z"),
      },
    ),
  );
  assertEquals(url.pathname, "/nile-replays/ev/1.mp4");
  assertEquals(url.searchParams.get("X-Amz-Expires"), "600");
  assertEquals(
    url.searchParams.get("X-Amz-Credential"),
    "k/20261124/auto/s3/aws4_request",
  );
});
