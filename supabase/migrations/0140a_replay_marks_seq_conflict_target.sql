-- 0140a: upsert(onConflict: grid_id,seq) can't target 0140's partial index; a
-- plain one works the same (NULL seqs — server-written tallies — never collide).
create unique index replay_marks_grid_seq on public.replay_marks (grid_id, seq);
