// The catch-all 500 responder. (P4 #45 of the 2026-08-16 platform review.)
//
// Every function ended its top-level try/catch with
//   return json({ error: String(err) }, 500)
// which hands the caller whatever the exception happened to say. In practice
// that meant Stripe account ids (`acct_…`), connected-account ids, Postgres
// constraint names — which name the tables and the columns — and internal row
// ids, all readable by anyone who could provoke a crash. The review counted
// eight functions; it was nineteen.
//
// Nothing is lost by hiding it: the full error and stack still go to the
// function log, keyed by a short reference the caller is told to quote. That
// is strictly better than before, because now an operator can tie a user's
// complaint to one exact log line instead of guessing from a timestamp.
//
// This is ONLY for the unexpected path. Deliberate 4xx replies elsewhere are
// written for the person reading them and should stay exactly as they are —
// "Free cancellation closed 24 hours before the event" is the whole point.

export interface FailureBody {
  error: string;
  ref: string;
}

/**
 * Log [err] in full against a short reference, and return the body to send.
 *
 *   } catch (err) {
 *     return json(failure(err, "refund-ticket"), 500);
 *   }
 */
export function failure(err: unknown, fn: string): FailureBody {
  const ref = crypto.randomUUID().slice(0, 8);
  console.error(
    JSON.stringify({
      level: "error",
      fn,
      ref,
      error: String(err),
      stack: err instanceof Error ? err.stack : undefined,
    }),
  );
  return {
    error:
      "Something went wrong on our end. Please try again — if it keeps " +
      `happening, quote reference ${ref} to support.`,
    ref,
  };
}
