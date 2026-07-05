-- VOD pricing, part 1: add the 'replay_price_prompt' notification type.
--
-- Split from the pricing schema + RPCs (0049) because Postgres cannot add an
-- enum value and use it in the same transaction. Mirrors the enum-first pattern
-- of 0044/0046.

alter type notification_type add value if not exists 'replay_price_prompt';
