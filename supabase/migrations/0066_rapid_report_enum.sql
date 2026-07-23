-- 0066: Rapids — report_target_type enum values (docs/plans/rapids.md, Phase 1).
-- Separate migration because an enum value added and USED in the same
-- transaction fails (same reasoning as 0019/0022). 0067 references these.

alter type report_target_type add value if not exists 'rapid';
alter type report_target_type add value if not exists 'rapid_comment';
