// Nile grid replay recorder — see index.html. The layout rules here are
// mirrored by nothing: the app reads the tiles this page reports, so they can
// change without an app release.
(function () {
  "use strict";

  /** What viewers can see, in the host's order (ShowControl.ordered in the app). */
  function pickTiles(meta, feeds) {
    const off = new Set(Array.isArray(meta.offAir) ? meta.offAir : []);
    const order = Array.isArray(meta.slotOrder) ? meta.slotOrder : [];
    const items = [];
    for (const f of feeds) {
      if (f.slot != null && off.has(f.slot)) continue;
      items.push({ key: f.key, s: f.share ? null : f.slot, el: null, rankId: f.slot, feed: f });
    }
    const els = meta.elements && Array.isArray(meta.elements.items) ? meta.elements.items : [];
    for (const e of els) {
      if (!e || e.angle !== true || typeof e.id !== "string") continue;
      const id = "el:" + e.id;
      if (off.has(id)) continue;
      items.push({ key: id, s: null, el: e.id, rankId: id, feed: null });
    }
    if (!order.length) return items;
    const rank = new Map(order.map((id, i) => [id, i]));
    return items
      .map((it, i) => ({ it, i, r: rank.has(it.rankId) ? rank.get(it.rankId) : order.length + i }))
      .sort((a, b) => a.r - b.r || a.i - b.i)
      .map((x) => x.it);
  }

  /** n 16:9 tiles in a W×H frame: as square a grid as fits, last row centred. */
  function layout(n, W, H, gap) {
    if (!n) return [];
    const cols = Math.ceil(Math.sqrt(n));
    const rows = Math.ceil(n / cols);
    const cw = W / cols, ch = H / rows;
    let tw = cw - gap, th = (tw * 9) / 16;
    if (th > ch - gap) { th = ch - gap; tw = (th * 16) / 9; }
    const r4 = (v) => Math.round(v * 10000) / 10000;
    const out = [];
    for (let i = 0; i < n; i++) {
      const row = Math.floor(i / cols), col = i % cols;
      const inRow = row === rows - 1 ? n - (rows - 1) * cols : cols;
      const x = (W - inRow * cw) / 2 + col * cw + (cw - tw) / 2;
      const y = row * ch + (ch - th) / 2;
      out.push([r4(x / W), r4(y / H), r4(tw / W), r4(th / H)]);
    }
    return out;
  }

  if (typeof module !== "undefined") {
    module.exports = { pickTiles, layout };
    return;
  }

  const LK = window.LivekitClient;
  const P = new URLSearchParams(location.search);
  const KEY = P.get("k"), FN = P.get("fn");
  const room = new LK.Room({ adaptiveStream: false, dynacast: false });

  // ── Marks: what replay-recorder stores, stamped with video time ───────────
  let seq = 0, t0 = null, queue = [], sending = false, lastMeta = null, lastTiles = null;
  const offset = () => (t0 == null ? 0 : Math.max(0, Math.round(performance.now() - t0)));
  const mark = (k, d) => queue.push({ s: seq++, o: offset(), k, d });

  async function flush() {
    if (sending || !queue.length || !KEY || !FN) return;
    sending = true;
    const batch = queue.slice(0, 100);
    try {
      // Plain-text body: a simple request, no CORS preflight.
      const res = await fetch(FN, { method: "POST", body: JSON.stringify({ key: KEY, marks: batch }) });
      // 4xx won't get better on retry; drop the batch rather than loop.
      if (res.ok || (res.status >= 400 && res.status < 500)) queue.splice(0, batch.length);
    } catch (_) { /* network: retried next tick */ }
    sending = false;
  }
  setInterval(flush, 1000);

  const roomMeta = () => {
    try { const m = JSON.parse(room.metadata || "{}"); return m && typeof m === "object" ? m : {}; }
    catch (_) { return {}; }
  };

  // ── Feeds: every camera and screen share with video ───────────────────────
  function feeds() {
    const out = [];
    for (const p of room.remoteParticipants.values()) {
      let meta = {};
      try { meta = JSON.parse(p.metadata || "{}") || {}; } catch (_) {}
      for (const pub of p.videoTrackPublications.values()) {
        const share = pub.source === LK.Track.Source.ScreenShare;
        if (!pub.track || (!share && pub.source !== LK.Track.Source.Camera)) continue;
        out.push({
          key: p.identity + ":" + pub.trackSid,
          slot: typeof meta.slotId === "string" ? meta.slotId : null,
          share,
          joined: p.joinedAt ? p.joinedAt.getTime() : 0,
          identity: p.identity,
          track: pub.track,
        });
      }
    }
    return out.sort((a, b) => a.joined - b.joined || (a.identity < b.identity ? -1 : a.identity > b.identity ? 1 : 0) || a.share - b.share);
  }

  // ── Render ────────────────────────────────────────────────────────────────
  const tiles = new Map(); // key → { div, video, track }

  function render() {
    const meta = roomMeta();
    const items = pickTiles(meta, feeds());
    const rects = layout(items.length, 1920, 1080, 12);
    const seen = new Set();
    items.forEach((it, i) => {
      seen.add(it.key);
      let t = tiles.get(it.key);
      if (!t) {
        const div = document.createElement("div");
        div.className = "tile";
        document.body.appendChild(div);
        t = { div, video: null, track: null };
        tiles.set(it.key, t);
      }
      const r = rects[i];
      Object.assign(t.div.style, { left: r[0] * 100 + "%", top: r[1] * 100 + "%", width: r[2] * 100 + "%", height: r[3] * 100 + "%" });
      const track = it.feed ? it.feed.track : null;
      if (track !== t.track) {
        if (t.video) { t.track && t.track.detach(t.video); t.video.remove(); t.video = null; }
        if (track) { t.video = track.attach(); t.video.muted = true; t.div.appendChild(t.video); }
        t.track = track;
      }
    });
    for (const [key, t] of tiles) {
      if (seen.has(key)) continue;
      if (t.video && t.track) t.track.detach(t.video);
      t.div.remove();
      tiles.delete(key);
    }
    if (t0 == null) return;
    const metaRaw = room.metadata || "";
    if (metaRaw !== lastMeta) { lastMeta = metaRaw; mark("meta", metaRaw); }
    const report = items.map((it, i) => ({ s: it.s, el: it.el, r: rects[i] }));
    const json = JSON.stringify(report);
    if (json !== lastTiles) { lastTiles = json; mark("tiles", report); }
  }

  // Audio: every published microphone, as the default recorder does.
  room.on(LK.RoomEvent.TrackSubscribed, (track) => {
    if (track.kind === LK.Track.Kind.Audio) {
      const el = track.attach();
      el.style.display = "none";
      document.body.appendChild(el);
    }
    render();
  });
  room.on(LK.RoomEvent.TrackUnsubscribed, (track) => {
    if (track.kind === LK.Track.Kind.Audio) track.detach().forEach((el) => el.remove());
    render();
  });
  for (const ev of [
    LK.RoomEvent.RoomMetadataChanged,
    LK.RoomEvent.ParticipantMetadataChanged,
    LK.RoomEvent.ParticipantConnected,
    LK.RoomEvent.ParticipantDisconnected,
    LK.RoomEvent.TrackPublished,
    LK.RoomEvent.TrackUnpublished,
  ]) room.on(ev, render);

  room.on(LK.RoomEvent.Disconnected, async () => {
    if (t0 != null) mark("end", {});
    const until = Date.now() + 3000;
    while (queue.length && Date.now() < until) { await flush(); await new Promise((r) => setTimeout(r, 200)); }
    console.log("END_RECORDING");
  });

  // Start once a camera is showing (or after 5 s regardless), like LiveKit's
  // own recorder, so the file doesn't open on black.
  function startWhenReady() {
    const began = Date.now();
    const timer = setInterval(() => {
      const hasVideo = [...tiles.values()].some((t) => t.video && t.video.videoWidth > 0);
      if (!hasVideo && Date.now() - began < 5000) return;
      clearInterval(timer);
      console.log("START_RECORDING");
      t0 = performance.now();
      mark("start", { wall: Date.now() });
      lastMeta = lastTiles = null;
      render();
      flush();
    }, 100);
  }

  room
    .connect(P.get("url"), P.get("token"))
    .then(() => { render(); startWhenReady(); })
    .catch((err) => { console.error("connect failed", err); console.log("END_RECORDING"); });
})();
