// Premiere synced playback (phases 7-8): the film clock, transport rules,
// chapters for the replay, chat during the film and the 18+ check.
//
//   deno test --allow-env supabase/functions/tests/

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  applyFilmControl,
  chatRuleDuringFilm,
  type FilmState,
  filmNow,
  filmOf,
  filmSpan,
  FILM_SLOW_MODE_S,
  initialFilm,
  isAdult,
} from "../_shared/film.ts";

const MIN = 60_000;
const film = (f: Partial<FilmState> = {}): FilmState => ({ ...initialFilm(90 * MIN, 0), ...f });
const ok = (r: ReturnType<typeof applyFilmControl>): FilmState => {
  if ("error" in r) throw new Error(r.error);
  return r.film;
};

Deno.test("the clock: playing advances, paused holds, the end rolls into post-show", () => {
  const f = film({ state: "playing", pos: 10_000, at: 1_000 });
  assertEquals(filmNow(f, 6_000), { phase: "playing", pos: 15_000, showingFilm: true });
  assertEquals(filmNow({ ...f, state: "paused" }, 60_000).pos, 10_000);
  const end = filmNow(f, 1_000 + 90 * MIN);
  assertEquals(end.phase, "ended");
  assertEquals(end.pos, 90 * MIN);
  assertEquals(end.showingFilm, false);
  assertEquals(filmNow(film(), 5_000), { phase: "pre", pos: 0, showingFilm: false });
});

Deno.test("an intermission resumes by itself when its time is up", () => {
  const f = film({ state: "intermission", pos: 20 * MIN, at: 0, until: 5 * MIN });
  assertEquals(filmNow(f, 4 * MIN).phase, "intermission");
  assertEquals(filmNow(f, 4 * MIN).pos, 20 * MIN);
  const after = filmNow(f, 6 * MIN);
  assertEquals(after.phase, "playing");
  assertEquals(after.pos, 21 * MIN);
});

Deno.test("transport: play, pause, intermission, hold, resume, seek, end, reset", () => {
  let f = ok(applyFilmControl(film(), { film: "play" }, 1_000, true));
  assertEquals([f.state, f.pos, f.at, f.startedAt], ["playing", 0, 1_000, 1_000]);
  f = ok(applyFilmControl(f, { film: "pause" }, 11_000, true));
  assertEquals([f.state, f.pos], ["paused", 10_000]);
  f = ok(applyFilmControl(f, { film: "resume" }, 20_000, true));
  assertEquals([f.state, f.pos, f.at, f.startedAt], ["playing", 10_000, 20_000, 1_000]);
  f = ok(applyFilmControl(f, { film: "intermission", seconds: 120 }, 30_000, true));
  assertEquals([f.state, f.pos, f.until], ["intermission", 20_000, 150_000]);
  f = ok(applyFilmControl(f, { film: "hold", message: "  Back in a moment  " }, 40_000, true));
  assertEquals([f.state, f.pos, f.msg, f.until], ["hold", 20_000, "Back in a moment", undefined]);
  f = ok(applyFilmControl(f, { film: "seek", positionMs: 5 * MIN }, 50_000, true));
  assertEquals([f.state, f.pos], ["hold", 5 * MIN]);
  f = ok(applyFilmControl(f, { film: "end" }, 60_000, true));
  assertEquals([f.state, f.pos, f.endedAt], ["ended", 90 * MIN, 60_000]);
  f = ok(applyFilmControl(f, { film: "reset" }, 70_000, true));
  assertEquals([f.state, f.pos, f.startedAt, f.endedAt], ["pre", 0, undefined, undefined]);
});

Deno.test("transport refuses what makes no sense", () => {
  const pre = film();
  assert("error" in applyFilmControl(pre, { film: "play" }, 0, false), "not live yet");
  assert("error" in applyFilmControl(film({ dur: 0 }), { film: "play" }, 0, true), "no film");
  assert("error" in applyFilmControl(pre, { film: "pause" }, 0, true));
  assert("error" in applyFilmControl(pre, { film: "end" }, 0, true));
  const playing = film({ state: "playing", at: 0 });
  assert("error" in applyFilmControl(playing, { film: "intermission", seconds: 30 }, 0, true));
  assert("error" in applyFilmControl(playing, { film: "intermission", seconds: 3600 }, 0, true));
  assert("error" in applyFilmControl(playing, { film: "hold", message: "x".repeat(141) }, 0, true));
  assert("error" in applyFilmControl(playing, { film: "seek" }, 0, true));
  assert("error" in applyFilmControl(playing, { film: "nope" }, 0, true));
  assert("error" in applyFilmControl(playing, { film: "pip", corner: "middle" }, 0, true));
  assert("error" in applyFilmControl(playing, { film: "commentary" }, 0, true));
});

Deno.test("commentary and picture-in-picture work before the show and keep the clock", () => {
  const f = film({ state: "playing", pos: 1_000, at: 500 });
  const c = ok(applyFilmControl(f, { film: "commentary", on: true }, 9_000, false));
  assertEquals([c.commentary, c.pos, c.at], [true, 1_000, 500]);
  assertEquals(ok(applyFilmControl(c, { film: "pip", corner: "br" }, 9_000, false)).pip, "br");
  // Pressing play again mid-film changes nothing.
  assertEquals(ok(applyFilmControl(f, { film: "play" }, 9_000, true)), f);
});

Deno.test("filmOf reads what film-control writes and rejects junk", () => {
  const f = ok(applyFilmControl(film(), { film: "play" }, 1_000, true));
  assertEquals(filmOf(JSON.parse(JSON.stringify(f)))?.state, "playing");
  assertEquals(filmOf(null), null);
  assertEquals(filmOf({ state: "dancing", pos: 0, at: 0, dur: 0 }), null);
  assertEquals(filmOf({ state: "paused", pos: "1", at: 0, dur: 0 }), null);
  assertEquals(filmOf({ state: "paused", pos: 0, at: 0, dur: 1, pip: "middle" })?.pip, "off");
});

Deno.test("the replay's chapters: where the film started and ended", () => {
  assertEquals(filmSpan(film()), null);
  const playing = film({ state: "playing", pos: 30 * MIN, at: 100 * MIN, startedAt: 60 * MIN });
  assertEquals(filmSpan(playing), { start: 60 * MIN, end: 160 * MIN });
  assertEquals(filmSpan(film({ state: "ended", startedAt: 1, endedAt: 2 })), { start: 1, end: 2 });
  assertEquals(filmSpan(film({ state: "paused", startedAt: 1 })), { start: 1, end: null });
});

Deno.test("chat during the film follows the filmmaker's choice, then reopens", () => {
  const playing = film({ state: "playing", at: 0 });
  assertEquals(chatRuleDuringFilm("open", playing, 1_000), null);
  assert(chatRuleDuringFilm("reactions", playing, 1_000) !== null && "block" in chatRuleDuringFilm("reactions", playing, 1_000)!);
  assertEquals(chatRuleDuringFilm("slow", playing, 1_000), { slowSeconds: FILM_SLOW_MODE_S });
  // Before the film and after it (the Q&A) chat is open.
  assertEquals(chatRuleDuringFilm("reactions", film(), 1_000), null);
  assertEquals(chatRuleDuringFilm("reactions", playing, 91 * MIN), null);
  assertEquals(chatRuleDuringFilm("reactions", null, 0), null);
});

Deno.test("18+: a store-held age band or a birthday 18 years back", () => {
  const now = Date.parse("2026-11-09T12:00:00Z");
  assert(isAdult({ age_lower_bound: 18 }, now));
  assert(!isAdult({ age_lower_bound: 16 }, now));
  assert(isAdult({ birthdate: "2008-11-09" }, now));
  assert(!isAdult({ birthdate: "2008-11-10" }, now));
  assert(!isAdult({ birthdate: null }, now));
  assert(!isAdult(null, now));
});
