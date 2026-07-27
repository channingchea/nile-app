-- 0074: give the currents bucket an explicit 50 MB ceiling and mime allowlist.
-- It previously had none, so oversized uploads failed against the project-wide
-- cap with a bare 413. Stating it here keeps the failure deterministic and
-- documents what the client compresses toward (CurrentService.maxUploadBytes).

update storage.buckets
set file_size_limit = 52428800, -- 50 MB
    allowed_mime_types = array[
      'video/mp4', 'video/quicktime',
      'image/jpeg', 'image/png', 'image/webp'
    ]
where id = 'currents';
