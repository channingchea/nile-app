// The FIRST Deno tests in this repo. (P4 #44: the review found zero tests for
// any edge function, alongside none for money, safety or streaming.)
//
// Run them with:
//   deno test --allow-env supabase/functions/tests/
//
// What's testable here is the pure logic — the request handlers are I/O all
// the way down and would need a live Supabase and Stripe to exercise. That is
// exactly why the pure parts are worth pinning: they're the bits where a
// mistake is silent.

import {
  assert,
  assertEquals,
  assertMatch,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { failure } from "../_shared/errors.ts";

// Swallow the console.error that failure() emits by design, and hand back what
// it logged so the test can assert on it.
function captureError<T>(fn: () => T): { result: T; logged: string[] } {
  const original = console.error;
  const logged: string[] = [];
  console.error = (...args: unknown[]) => logged.push(args.map(String).join(" "));
  try {
    return { result: fn(), logged };
  } finally {
    console.error = original;
  }
}

Deno.test("failure() does not leak the exception text to the caller", () => {
  // The real shapes that used to reach clients: a Stripe account id, a
  // Postgres constraint name (which names the table and the column), and an
  // internal row id.
  const secrets = [
    "No such destination: acct_1TcHg7AUonuvwLuv",
    'duplicate key value violates unique constraint "tickets_event_id_buyer_id_key"',
    "row 9f3c1b7e-0000-4000-8000-000000000001 not found",
  ];

  for (const secret of secrets) {
    const { result, logged } = captureError(() =>
      failure(new Error(secret), "test-fn")
    );
    assert(
      !result.error.includes(secret),
      `leaked to caller: ${result.error}`,
    );
    // ...but it must still be recoverable by an operator. Decode the log line
    // rather than substring-matching it: the payload is JSON, so a constraint
    // name arrives with its quotes escaped and a raw match would miss it —
    // which would have made this assertion quietly meaningless.
    const line = JSON.parse(logged[0]);
    assertStringIncludes(line.error, secret);
  }
});

Deno.test("failure() gives the caller something to quote, and logs the same ref", () => {
  const { result, logged } = captureError(() => failure(new Error("boom"), "test-fn"));

  assertMatch(result.ref, /^[0-9a-f]{8}$/);
  assertStringIncludes(result.error, result.ref);

  // The whole point of the reference is joining the two sides.
  const line = JSON.parse(logged[0]);
  assertEquals(line.ref, result.ref);
  assertEquals(line.fn, "test-fn");
  assertEquals(line.level, "error");
});

Deno.test("failure() handles a non-Error throw without itself throwing", () => {
  // `throw "string"` and `throw {code: 42}` are both legal and both happen.
  for (const thrown of ["just a string", { code: 42 }, null, undefined]) {
    const { result } = captureError(() => failure(thrown, "test-fn"));
    assertMatch(result.ref, /^[0-9a-f]{8}$/);
    assert(result.error.length > 0);
  }
});

Deno.test("two failures never share a reference", () => {
  const { result: a } = captureError(() => failure(new Error("x"), "f"));
  const { result: b } = captureError(() => failure(new Error("x"), "f"));
  assert(a.ref !== b.ref);
});
