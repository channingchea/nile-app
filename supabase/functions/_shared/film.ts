// Premiere synced playback (docs/plans/studio-modes.md, phases 7-8): the film
// clock every viewer follows. Pure, so it can be unit tested. Mirrors
// lib/services/film_sync.dart.
//
// The host's Studio drives it with livekit `film-control`; the state lives in
// room metadata `film` (pushed to everyone in the room) and in
// event_films.film_state (read by live-chat and the replay). A device never
// asks "where is the film?": it computes it from {state, pos, at} and the
// shared server clock.

export const FILM_STATES = ["pre", "playing", "paused", "intermission", "hold", "ended"] as const;
export type FilmPhase = typeof FILM_STATES[number];
export const PIP_CORNERS = ["off", "tl", "tr", "bl", "br"] as const;
export type PipCorner = typeof PIP_CORNERS[number];

export const MIN_INTERMISSION_S = 60;
export const MAX_INTERMISSION_S = 30 * 60;
export const MAX_HOLD_MESSAGE = 140;
/** Slow mode floor while the film plays when the filmmaker picked "slow". */
export const FILM_SLOW_MODE_S = 10;

export type FilmState = {
  state: FilmPhase;
  /** Film position in ms at server time [at]. */
  pos: number;
  at: number;
  /** Film length in ms. */
  dur: number;
  /** Intermission ends (server ms); the film carries on by itself then. */
  until?: number;
  /** Hold slate text. */
  msg?: string;
  commentary: boolean;
  pip: PipCorner;
  /** Server ms of the first Play, and of the end (played out or ended by hand). */
  startedAt?: number;
  endedAt?: number;
};

export const initialFilm = (dur: number, now: number): FilmState => ({
  state: "pre",
  pos: 0,
  at: now,
  dur: Math.max(0, Math.round(dur)),
  commentary: false,
  pip: "off",
});

/** Reads room metadata `film` (or the stored copy); null when absent or malformed. */
export function filmOf(raw: unknown): FilmState | null {
  if (!raw || typeof raw !== "object") return null;
  const f = raw as Record<string, unknown>;
  if (!FILM_STATES.includes(f.state as FilmPhase)) return null;
  const n = (v: unknown) => (typeof v === "number" && isFinite(v) ? v : null);
  const pos = n(f.pos), at = n(f.at), dur = n(f.dur);
  if (pos === null || at === null || dur === null) return null;
  return {
    state: f.state as FilmPhase,
    pos,
    at,
    dur,
    ...(n(f.until) !== null ? { until: n(f.until)! } : {}),
    ...(typeof f.msg === "string" ? { msg: f.msg } : {}),
    commentary: f.commentary === true,
    pip: PIP_CORNERS.includes(f.pip as PipCorner) ? (f.pip as PipCorner) : "off",
    ...(n(f.startedAt) !== null ? { startedAt: n(f.startedAt)! } : {}),
    ...(n(f.endedAt) !== null ? { endedAt: n(f.endedAt)! } : {}),
  };
}

export type FilmNow = {
  /** What viewers see: the film segment is playing/paused/intermission/hold. */
  phase: FilmPhase;
  /** Where the film is now, ms (clamped to its length). */
  pos: number;
  /** True while the film stage is up (between Play and the end). */
  showingFilm: boolean;
};

/**
 * Where the film is at server time [now]. A playing film that has run past
 * its length has ended (the credits rolled: post-show starts by itself), and
 * an intermission past its end time is playing again from where it stopped.
 */
export function filmNow(f: FilmState, now: number): FilmNow {
  let phase = f.state;
  let pos = f.pos;
  if (phase === "intermission" && f.until !== undefined && now >= f.until) {
    phase = "playing";
    pos = f.pos + (now - f.until);
  } else if (phase === "playing") {
    pos = f.pos + Math.max(0, now - f.at);
  }
  if (phase === "playing" && f.dur > 0 && pos >= f.dur) phase = "ended";
  pos = Math.min(Math.max(0, pos), f.dur);
  const showingFilm = phase === "playing" || phase === "paused" || phase === "intermission" || phase === "hold";
  return { phase, pos, showingFilm };
}

export type FilmAction =
  | "play" | "pause" | "resume" | "seek" | "intermission" | "hold" | "end" | "reset" | "commentary" | "pip";
export const FILM_ACTIONS: FilmAction[] = [
  "play", "pause", "resume", "seek", "intermission", "hold", "end", "reset", "commentary", "pip",
];

/**
 * One transport press → the next state. [live] is whether the show is on air:
 * the film only moves while it is (viewers in the lobby can't watch yet).
 */
export function applyFilmControl(
  cur: FilmState,
  body: Record<string, unknown>,
  now: number,
  live: boolean,
): { film: FilmState } | { error: string; status: number } {
  const action = body.film as FilmAction;
  if (!FILM_ACTIONS.includes(action)) return { error: "Unknown film control", status: 400 };
  const n = filmNow(cur, now);
  const moving = !["commentary", "pip"].includes(action);
  if (moving && !live) return { error: "Start the show first", status: 409 };
  if (moving && cur.dur <= 0) return { error: "The film isn't ready", status: 409 };
  const base = { ...cur };
  delete base.until;
  delete base.msg;
  switch (action) {
    case "play":
    case "resume": {
      if (n.phase === "playing") return { film: cur };
      const from = n.phase === "pre" || n.phase === "ended" ? 0 : n.pos;
      return {
        film: { ...base, state: "playing", pos: from, at: now, startedAt: cur.startedAt ?? now, endedAt: undefined },
      };
    }
    case "pause":
      if (!n.showingFilm) return { error: "The film isn't playing", status: 409 };
      return { film: { ...base, state: "paused", pos: n.pos, at: now } };
    case "seek": {
      const p = body.positionMs;
      if (typeof p !== "number" || !isFinite(p)) return { error: "positionMs is required", status: 400 };
      if (!n.showingFilm) return { error: "Play the film first", status: 409 };
      const state = n.phase === "intermission" ? "paused" : n.phase;
      return { film: { ...base, state, pos: Math.min(Math.max(0, Math.round(p)), cur.dur), at: now } };
    }
    case "intermission": {
      const s = body.seconds;
      if (typeof s !== "number" || !Number.isInteger(s) || s < MIN_INTERMISSION_S || s > MAX_INTERMISSION_S) {
        return { error: "Intermissions are 1 to 30 minutes", status: 400 };
      }
      if (!n.showingFilm) return { error: "Play the film first", status: 409 };
      return { film: { ...base, state: "intermission", pos: n.pos, at: now, until: now + s * 1000 } };
    }
    case "hold": {
      const m = typeof body.message === "string" ? body.message.trim() : "";
      if (m.length > MAX_HOLD_MESSAGE) return { error: `Hold messages are up to ${MAX_HOLD_MESSAGE} characters`, status: 400 };
      if (!n.showingFilm) return { error: "Play the film first", status: 409 };
      return { film: { ...base, state: "hold", pos: n.pos, at: now, ...(m ? { msg: m } : {}) } };
    }
    case "end":
      if (n.phase === "pre") return { error: "The film hasn't started", status: 409 };
      return { film: { ...base, state: "ended", pos: cur.dur, at: now, endedAt: cur.endedAt ?? now } };
    case "reset":
      return { film: { ...base, state: "pre", pos: 0, at: now, startedAt: undefined, endedAt: undefined } };
    case "commentary":
      if (typeof body.on !== "boolean") return { error: "on must be true or false", status: 400 };
      return { film: { ...cur, commentary: body.on } };
    case "pip":
      if (!PIP_CORNERS.includes(body.corner as PipCorner)) return { error: "Pick a corner", status: 400 };
      return { film: { ...cur, pip: body.corner as PipCorner } };
  }
}

/** Drops undefined keys so the JSON stays tidy. */
export const compactFilm = (f: FilmState): FilmState =>
  Object.fromEntries(Object.entries(f).filter(([, v]) => v !== undefined)) as FilmState;

/**
 * When the film segment started and ended (server ms), for the replay's
 * chapters. A film that played out by itself ends where its clock ran out.
 */
export function filmSpan(f: FilmState | null): { start: number; end: number | null } | null {
  if (!f || f.startedAt === undefined) return null;
  if (f.endedAt !== undefined) return { start: f.startedAt, end: f.endedAt };
  if (f.state === "playing") return { start: f.startedAt, end: f.at + Math.max(0, f.dur - f.pos) };
  return { start: f.startedAt, end: null };
}

/**
 * Chat while the film plays: the filmmaker's choice. Reactions-only blocks
 * text; slow mode is at least [FILM_SLOW_MODE_S]. Chat opens up again once
 * the film is over (the Q&A).
 */
export function chatRuleDuringFilm(
  policy: string | null | undefined,
  film: FilmState | null,
  now: number,
): { block: string } | { slowSeconds: number } | null {
  if (!film || !filmNow(film, now).showingFilm) return null;
  if (policy === "reactions") return { block: "During the film, chat is reactions only" };
  if (policy === "slow") return { slowSeconds: FILM_SLOW_MODE_S };
  return null;
}

/** 18+ films: may this person (their user_age_verification row) watch? */
export function isAdult(row: { birthdate?: string | null; age_lower_bound?: number | null } | null, now: number): boolean {
  if (!row) return false;
  if (typeof row.age_lower_bound === "number" && row.age_lower_bound >= 18) return true;
  if (!row.birthdate) return false;
  const b = new Date(`${row.birthdate}T00:00:00Z`);
  if (isNaN(b.getTime())) return false;
  const d = new Date(now);
  let age = d.getUTCFullYear() - b.getUTCFullYear();
  if (d.getUTCMonth() < b.getUTCMonth() || (d.getUTCMonth() === b.getUTCMonth() && d.getUTCDate() < b.getUTCDate())) age--;
  return age >= 18;
}
