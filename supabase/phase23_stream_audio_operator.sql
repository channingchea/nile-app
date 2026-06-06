-- Phase 23: Stream Audio Operator
-- Adds is_audio_operator flag to event_operators so the crew editor can
-- designate one operator as the dedicated Stream Audio device.

ALTER TABLE event_operators
  ADD COLUMN IF NOT EXISTS is_audio_operator BOOLEAN NOT NULL DEFAULT FALSE;

-- Update assign_event_operator to accept the new flag.
-- Replaces the function created in the create-event flow phase.
CREATE OR REPLACE FUNCTION assign_event_operator(
  p_event_id        UUID,
  p_operator_id     UUID,
  p_camera_id       UUID    DEFAULT NULL,
  p_is_audio_operator BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_host_id UUID;
BEGIN
  SELECT host_id INTO v_host_id FROM events WHERE id = p_event_id;

  -- Host is always implicitly a crew member; skip inserting a row for them.
  IF v_host_id = p_operator_id THEN
    RETURN;
  END IF;

  INSERT INTO event_operators (event_id, operator_id, camera_id, is_audio_operator)
  VALUES (p_event_id, p_operator_id, p_camera_id, p_is_audio_operator)
  ON CONFLICT (event_id, operator_id)
  DO UPDATE SET
    camera_id = EXCLUDED.camera_id,
    is_audio_operator = EXCLUDED.is_audio_operator;
END;
$$;
