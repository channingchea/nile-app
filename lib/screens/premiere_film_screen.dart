import 'dart:async';
import 'dart:io';

import 'package:croppy/croppy.dart' show CropAspectRatio;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import 'package:video_player/video_player.dart';

import '../router.dart';
import '../services/event_service.dart';
import '../services/formats.dart';
import '../services/premiere.dart';
import '../services/premiere_service.dart';
import '../services/profile_service.dart';
import '../services/studio_mode.dart';
import '../theme.dart';
import '../widgets/premiere_checklist.dart';

/// Premiere mode, the host's side (docs/plans/studio-modes.md, phase 6): upload
/// the film and trailer to Cloudflare Stream, add captions and a poster, and
/// set the rating, replay and chat choices. `/event/:id/film`.
class PremiereFilmScreen extends StatefulWidget {
  const PremiereFilmScreen({super.key, required this.eventId});

  final String eventId;

  @override
  State<PremiereFilmScreen> createState() => _PremiereFilmScreenState();
}

const _videoTypes = XTypeGroup(
  label: 'Video',
  extensions: ['mp4', 'mov', 'm4v', 'mkv', 'webm', 'avi', 'mpg', 'mpeg', 'mxf'],
  uniformTypeIdentifiers: ['public.movie'],
  mimeTypes: ['video/*'],
);

const _captionTypes = XTypeGroup(
  label: 'Captions',
  extensions: ['srt', 'vtt'],
  uniformTypeIdentifiers: ['public.plain-text', 'public.data'],
  mimeTypes: ['text/plain', 'text/vtt', 'application/x-subrip'],
);

const _maxFilmBytes = 30 * 1024 * 1024 * 1024;
const _maxTrailerBytes = 4 * 1024 * 1024 * 1024;

class _PremiereFilmScreenState extends State<PremiereFilmScreen> {
  Event? _event;
  EventFilm? _film;
  String? _loadError;
  RealtimeChannel? _channel;
  Timer? _poll;
  final _warning = TextEditingController();
  final _resumable = <FilmKind, ({String path, Uri url, String name})?>{};
  final _wasRunning = <FilmKind, bool>{};
  bool _busy = false;

  PremiereUploads get _uploads => PremiereUploads.instance;

  @override
  void initState() {
    super.initState();
    _uploads.addListener(_onUploads);
    unawaited(_load());
  }

  @override
  void dispose() {
    _uploads.removeListener(_onUploads);
    _channel?.unsubscribe();
    _poll?.cancel();
    _warning.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _plain(Object e) => e.toString().replaceFirst('Exception: ', '');

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        EventService.fetchById(widget.eventId),
        PremiereService.fetch(widget.eventId),
      ]);
      if (!mounted) return;
      final event = results[0] as Event?;
      if (event == null) throw Exception('This event isn’t available.');
      setState(() {
        _event = event;
        _setFilm(results[1] as EventFilm);
        _warning.text = _film!.contentWarning ?? '';
      });
      _channel = PremiereService.watch(widget.eventId, _reload);
      await _checkResumable();
    } catch (e) {
      if (mounted) setState(() => _loadError = _plain(e));
    }
  }

  Future<void> _reload() async {
    try {
      final film = await PremiereService.fetch(widget.eventId);
      if (mounted) setState(() => _setFilm(film));
    } catch (_) {}
  }

  Future<void> _checkResumable() async {
    for (final k in FilmKind.values) {
      _resumable[k] = await _uploads.resumable(widget.eventId, k);
    }
    if (mounted) setState(() {});
  }

  /// Takes a new row and keeps a slow poll going while Stream processes, in
  /// case the webhook is late.
  void _setFilm(EventFilm film) {
    _film = film;
    final waiting = FilmKind.values.any(
      (k) =>
          film.statusOf(k) == MediaStatus.processing ||
          (film.statusOf(k) == MediaStatus.uploading &&
              _uploads.job(widget.eventId, k)?.running != true),
    );
    if (waiting && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 20), (_) async {
        try {
          final f = await PremiereService.refresh(widget.eventId);
          if (f != null && mounted) setState(() => _setFilm(f));
        } catch (_) {}
      });
    } else if (!waiting) {
      _poll?.cancel();
      _poll = null;
    }
  }

  void _onUploads() {
    if (!mounted) return;
    for (final k in FilmKind.values) {
      final running = _uploads.job(widget.eventId, k)?.running ?? false;
      if (_wasRunning[k] == true && !running) {
        unawaited(_reload());
        unawaited(_checkResumable());
      }
      _wasRunning[k] = running;
    }
    setState(() {});
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: NileColors.bgSurface,
          title: Text(title, style: NileTextStyles.headingMd()),
          content: Text(body, style: NileTextStyles.bodyMd()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  // ── Film and trailer ───────────────────────────────────────────────────────

  Future<void> _pick(FilmKind kind) async {
    final film = _film!;
    final XFile? x;
    try {
      x = await openFile(acceptedTypeGroups: const [_videoTypes]);
    } catch (e) {
      return _toast('Couldn’t open that file: ${_plain(e)}');
    }
    if (x == null) return;
    final file = File(x.path);
    final size = await file.length();
    final cap = kind == FilmKind.film ? _maxFilmBytes : _maxTrailerBytes;
    if (size > cap) {
      return _toast(
        kind == FilmKind.film
            ? 'Films can be up to 30 GB.'
            : 'Trailers can be up to 4 GB.',
      );
    }
    final status = film.statusOf(kind);
    if (status != MediaStatus.none &&
        !await _confirm(
          kind == FilmKind.film ? 'Replace the film?' : 'Replace the trailer?',
          'The current upload is deleted and ${x.name} takes its place.',
          'Replace',
        )) {
      return;
    }
    await _uploads.forget(widget.eventId, kind);
    _resumable[kind] = null;
    unawaited(
      _uploads.start(
        eventId: widget.eventId,
        kind: kind,
        file: file,
        name: x.name,
        replace: true,
      ),
    );
  }

  Future<void> _delete(FilmKind kind) async {
    final ok = await _confirm(
      kind == FilmKind.film ? 'Delete the film?' : 'Delete the trailer?',
      kind == FilmKind.film
          ? 'It’s removed from Nile, with its captions. Your own copy isn’t touched.'
          : 'It’s removed from Nile. Your own copy isn’t touched.',
      'Delete',
    );
    if (!ok) return;
    await _run(() => PremiereService.deleteMedia(widget.eventId, kind));
    _resumable[kind] = null;
  }

  Future<void> _preview(FilmKind kind) async {
    try {
      final url = kind == FilmKind.film
          ? await PremiereService.filmUrl(widget.eventId)
          : (await PremiereService.trailer(widget.eventId)).url;
      if (url == null || !mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _PreviewDialog(url: url),
      );
    } catch (e) {
      _toast(_plain(e));
    }
  }

  // ── Details ────────────────────────────────────────────────────────────────

  /// Runs a request that returns the new row.
  Future<void> _run(Future<EventFilm?> Function() call) async {
    setState(() => _busy = true);
    try {
      final f = await call();
      if (f != null && mounted) setState(() => _setFilm(f));
    } catch (e) {
      _toast(_plain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveWarning() async {
    final text = _warning.text.trim();
    if (text == (_film?.contentWarning ?? '')) return;
    await _run(
      () => PremiereService.setDetails(widget.eventId, contentWarning: text),
    );
  }

  Future<void> _addCaptions() async {
    final lang = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Caption language', style: NileTextStyles.headingSm()),
        children: [
          for (final e in kCaptionLanguages.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e.key),
              child: Text(e.value, style: NileTextStyles.bodyMd()),
            ),
        ],
      ),
    );
    if (lang == null) return;
    final XFile? x;
    try {
      x = await openFile(acceptedTypeGroups: const [_captionTypes]);
    } catch (e) {
      return _toast('Couldn’t open that file: ${_plain(e)}');
    }
    if (x == null) return;
    if (await x.length() > 2 * 1024 * 1024) {
      return _toast('That caption file is too large (2 MB max).');
    }
    final String text;
    try {
      text = await x.readAsString();
    } catch (_) {
      return _toast('That file isn’t a text caption file.');
    }
    await _run(
      () => PremiereService.addCaptions(
        widget.eventId,
        lang: lang,
        label: kCaptionLanguages[lang]!,
        text: text,
      ),
    );
  }

  Future<void> _pickPoster() async {
    final slug = _event?.liveKitEventId;
    if (slug == null) return _toast('Save the event first.');
    final bytes = await ProfileService.pickImageBytes(
      context,
      maxWidth: 1000,
      maxHeight: 1500,
      allowedAspectRatios: [const CropAspectRatio(width: 2, height: 3)],
    );
    if (bytes == null) return;
    await _run(
      () => PremiereService.uploadPoster(
        eventId: widget.eventId,
        slug: slug,
        bytes: bytes,
      ),
    );
  }

  // ── Layout ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final event = _event, film = _film;
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Film', style: NileTextStyles.headingSm()),
      ),
      body: NileMaxWidth(
        child: _loadError != null
            ? _Notice(text: _loadError!)
            : event == null || film == null
            ? const Center(child: CircularProgressIndicator())
            : event.studioMode != StudioMode.premiere
            ? _Notice(
                text:
                    'This event isn’t a Premiere. Switch its Studio Mode to '
                    'Premiere and save, then upload your film here.',
                action: 'Edit event',
                onAction: () => context.push(NileRoutes.eventEdit(event.id)),
              )
            : _body(event, film),
      ),
    );
  }

  Widget _body(Event event, EventFilm film) {
    final locked = event.isOver;
    final filmReady = film.filmStatus == MediaStatus.ready;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s16,
        NileSpacing.s8,
        NileSpacing.s16,
        NileSpacing.s48,
      ),
      children: [
        Text(event.title, style: NileTextStyles.headingMd()),
        const SizedBox(height: NileSpacing.s16),
        PremiereChecklist(film: film),
        if (film.deleteAfter != null) ...[
          const SizedBox(height: NileSpacing.s12),
          Text(
            'This film will be removed from Nile on '
            '${NileFormats.dayMonthYearTime(film.deleteAfter!.toLocal())}.',
            style: NileTextStyles.bodySm().copyWith(color: NileColors.warning),
          ),
        ],
        _Section(
          title: 'Film',
          subtitle:
              'Up to 8 hours and 30 GB. A computer is best for big files: '
              'keep Nile open until the upload finishes.',
          child: _MediaCard(
            kind: FilmKind.film,
            film: film,
            job: _uploads.job(widget.eventId, FilmKind.film),
            resumable: _resumable[FilmKind.film],
            locked: locked,
            onPick: () => _pick(FilmKind.film),
            onResume: () => _uploads.resume(widget.eventId, FilmKind.film),
            onPause: () => _uploads.cancel(widget.eventId, FilmKind.film),
            onDelete: () => _delete(FilmKind.film),
            onPreview: () => _preview(FilmKind.film),
          ),
        ),
        _Section(
          title: 'Trailer',
          subtitle:
              'Optional, up to 5 minutes. It plays on the event page and in '
              'the countdown lobby for everyone, with or without a ticket.',
          child: _MediaCard(
            kind: FilmKind.trailer,
            film: film,
            job: _uploads.job(widget.eventId, FilmKind.trailer),
            resumable: _resumable[FilmKind.trailer],
            locked: locked,
            onPick: () => _pick(FilmKind.trailer),
            onResume: () => _uploads.resume(widget.eventId, FilmKind.trailer),
            onPause: () => _uploads.cancel(widget.eventId, FilmKind.trailer),
            onDelete: () => _delete(FilmKind.trailer),
            onPreview: () => _preview(FilmKind.trailer),
          ),
        ),
        _Section(
          title: 'Captions',
          subtitle: filmReady
              ? 'Add .srt or .vtt files. Viewers can turn them on during the film.'
              : 'You can add captions once the film has finished processing.',
          child: Wrap(
            spacing: NileSpacing.s8,
            runSpacing: NileSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final c in film.captions)
                InputChip(
                  label: Text(c.label),
                  onDeleted: _busy || locked
                      ? null
                      : () => _run(
                          () => PremiereService.removeCaptions(
                            widget.eventId,
                            c.lang,
                          ),
                        ),
                ),
              OutlinedButton.icon(
                onPressed: filmReady && !_busy && !locked ? _addCaptions : null,
                icon: const Icon(Icons.closed_caption_outlined, size: 18),
                label: const Text('Add captions'),
              ),
            ],
          ),
        ),
        _Section(
          title: 'Poster',
          subtitle:
              'Optional. Shown before the film and while the trailer loads.',
          child: Row(
            children: [
              if (film.posterUrl != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(NileRadius.sm),
                  child: Image.network(
                    film.posterUrl!,
                    width: 64,
                    height: 96,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const SizedBox(width: 64, height: 96),
                  ),
                ),
                const SizedBox(width: NileSpacing.s12),
              ],
              OutlinedButton(
                onPressed: _busy || locked ? null : _pickPoster,
                child: Text(
                  film.posterUrl == null ? 'Choose poster' : 'Change',
                ),
              ),
              if (film.posterUrl != null) ...[
                const SizedBox(width: NileSpacing.s8),
                TextButton(
                  onPressed: _busy || locked
                      ? null
                      : () => _run(
                          () => PremiereService.setDetails(
                            widget.eventId,
                            clearPoster: true,
                          ),
                        ),
                  child: const Text('Remove'),
                ),
              ],
            ],
          ),
        ),
        _Section(
          title: 'Rating',
          subtitle: 'Shown on a card before the film. 18+ runs an age check.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Choices<FilmRating>(
                values: FilmRating.values,
                selected: film.rating,
                label: (r) => r.label,
                onSelected: _busy || locked
                    ? null
                    : (r) => _run(
                        () => PremiereService.setDetails(
                          widget.eventId,
                          rating: r,
                        ),
                      ),
              ),
              const SizedBox(height: NileSpacing.s12),
              Focus(
                onFocusChange: (f) {
                  if (!f) unawaited(_saveWarning());
                },
                child: TextField(
                  controller: _warning,
                  enabled: !locked,
                  maxLength: 200,
                  onSubmitted: (_) => _saveWarning(),
                  decoration: const InputDecoration(
                    labelText: 'Content warning (optional)',
                    hintText: 'e.g. Flashing lights, strong language',
                  ),
                ),
              ),
            ],
          ),
        ),
        _Section(
          title: 'Replay',
          subtitle:
              'How long ticket holders can rewatch after the show. Films are '
              'removed from Nile 7 days after the show, or when the replay '
              'ends if that’s later.',
          child: _Choices<ReplayPolicy>(
            values: ReplayPolicy.values,
            selected: film.replay,
            label: (p) => p.label,
            onSelected: _busy
                ? null
                : (p) => _run(
                    () => PremiereService.setDetails(widget.eventId, replay: p),
                  ),
          ),
        ),
        _Section(
          title: 'Chat during the film',
          subtitle: 'Chat opens fully again for the Q&A after the film.',
          child: _Choices<ChatPolicy>(
            values: ChatPolicy.values,
            selected: film.chat,
            label: (p) => p.label,
            onSelected: _busy || locked
                ? null
                : (p) => _run(
                    () => PremiereService.setDetails(widget.eventId, chat: p),
                  ),
          ),
        ),
        const SizedBox(height: NileSpacing.s24),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: film.rightsConfirmedAt != null,
          onChanged: _busy || locked
              ? null
              : (v) => _run(
                  () => PremiereService.setDetails(
                    widget.eventId,
                    rightsConfirmed: v ?? false,
                  ),
                ),
          title: Text(
            'I own the rights to show this film, or have permission from '
            'whoever does.',
            style: NileTextStyles.bodyMd(),
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: NileSpacing.s24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: NileTextStyles.labelMd()),
        if (subtitle != null) ...[
          const SizedBox(height: NileSpacing.s4),
          Text(
            subtitle!,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
        ],
        const SizedBox(height: NileSpacing.s12),
        child,
      ],
    ),
  );
}

class _Choices<T> extends StatelessWidget {
  const _Choices({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final List<T> values;
  final T? selected;
  final String Function(T) label;
  final ValueChanged<T>? onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: NileSpacing.s8,
    runSpacing: NileSpacing.s8,
    children: [
      for (final v in values)
        ChoiceChip(
          label: Text(label(v)),
          selected: v == selected,
          onSelected: onSelected == null || v == selected
              ? null
              : (_) => onSelected!(v),
        ),
    ],
  );
}

/// One upload slot (film or trailer) in whatever state it's in.
class _MediaCard extends StatelessWidget {
  const _MediaCard({
    required this.kind,
    required this.film,
    required this.job,
    required this.resumable,
    required this.locked,
    required this.onPick,
    required this.onResume,
    required this.onPause,
    required this.onDelete,
    required this.onPreview,
  });

  final FilmKind kind;
  final EventFilm film;
  final UploadJob? job;
  final ({String path, Uri url, String name})? resumable;
  final bool locked;
  final VoidCallback onPick;
  final VoidCallback onResume;
  final VoidCallback onPause;
  final VoidCallback onDelete;
  final VoidCallback onPreview;

  String get _noun => kind == FilmKind.film ? 'film' : 'trailer';

  @override
  Widget build(BuildContext context) {
    final status = film.statusOf(kind);
    final j = job;
    final Widget body;
    final List<Widget> actions;

    if (j != null && j.running) {
      body = _Line(
        icon: Icons.cloud_upload_outlined,
        title: 'Uploading ${j.fileName}',
        detail: j.total == 0
            ? 'Starting…'
            : '${formatBytes(j.sent)} of ${formatBytes(j.total)} '
                  '(${(j.progress * 100).floor()}%)',
        progress: j.total == 0 ? null : j.progress,
      );
      actions = [TextButton(onPressed: onPause, child: const Text('Pause'))];
    } else if (j?.error != null) {
      body = _Line(
        icon: Icons.error_outline,
        color: NileColors.error,
        title: 'The upload stopped',
        detail: j!.error!,
      );
      actions = [
        if (!j.expired && resumable != null)
          FilledButton(onPressed: onResume, child: const Text('Resume')),
        OutlinedButton(onPressed: onPick, child: const Text('Choose file')),
      ];
    } else if (resumable != null && status == MediaStatus.uploading) {
      body = _Line(
        icon: Icons.pause_circle_outline,
        title: 'Upload paused',
        detail: resumable!.name,
      );
      actions = [
        FilledButton(onPressed: onResume, child: const Text('Resume')),
        OutlinedButton(onPressed: onPick, child: const Text('Start over')),
      ];
    } else {
      switch (status) {
        case MediaStatus.none:
          body = _Line(
            icon: kind == FilmKind.film
                ? Icons.movie_outlined
                : Icons.slideshow_outlined,
            title: 'No $_noun yet',
            detail: 'MP4 or MOV works best.',
          );
          actions = [
            FilledButton(
              onPressed: locked ? null : onPick,
              child: Text('Choose $_noun'),
            ),
          ];
        case MediaStatus.uploading:
          body = _Line(
            icon: Icons.cloud_upload_outlined,
            title: 'Upload not finished',
            detail:
                'It started on another device or was interrupted. Start it '
                'again from here.',
          );
          actions = [
            OutlinedButton(
              onPressed: locked ? null : onPick,
              child: const Text('Choose file'),
            ),
          ];
        case MediaStatus.processing:
          body = _Line(
            icon: Icons.hourglass_top,
            title: 'Processing',
            detail:
                'Your $_noun is uploaded. It’s being prepared for streaming, '
                'which can take a while for long films.',
            progress: null,
          );
          actions = const [];
        case MediaStatus.ready:
          final d = film.durationOf(kind);
          body = _Line(
            icon: Icons.check_circle,
            color: NileColors.success,
            title: kind == FilmKind.film
                ? (film.filmName ?? 'Film ready')
                : 'Trailer ready',
            detail: [
              if (d != null) formatFilmLength(d),
              if (kind == FilmKind.film && film.filmBytes != null)
                formatBytes(film.filmBytes!),
            ].join(' · '),
          );
          actions = [
            FilledButton.tonal(
              onPressed: onPreview,
              child: const Text('Preview'),
            ),
            OutlinedButton(
              onPressed: locked ? null : onPick,
              child: const Text('Replace'),
            ),
            TextButton(
              onPressed: locked ? null : onDelete,
              child: Text('Delete', style: TextStyle(color: NileColors.error)),
            ),
          ];
        case MediaStatus.error:
          body = _Line(
            icon: Icons.error_outline,
            color: NileColors.error,
            title: 'Stream couldn’t process this $_noun',
            detail: film.errorOf(kind) ?? 'Try a different file.',
          );
          actions = [
            OutlinedButton(
              onPressed: locked ? null : onPick,
              child: const Text('Choose another file'),
            ),
          ];
      }
    }

    return Container(
      padding: const EdgeInsets.all(NileSpacing.s12),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.md),
        border: Border.all(color: NileColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          if (actions.isNotEmpty) ...[
            const SizedBox(height: NileSpacing.s12),
            Wrap(
              spacing: NileSpacing.s8,
              runSpacing: NileSpacing.s8,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.title,
    required this.detail,
    this.color,
    this.progress = -1,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color? color;

  /// -1 = no bar, null = indeterminate, 0-1 = progress.
  final double? progress;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color ?? NileColors.txtPrimary),
          const SizedBox(width: NileSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NileTextStyles.labelMd(),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      if (progress != -1) ...[
        const SizedBox(height: NileSpacing.s8),
        ClipRRect(
          borderRadius: BorderRadius.circular(NileRadius.pill),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: NileColors.bgRaised,
            color: NileColors.volt,
          ),
        ),
      ],
    ],
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(NileSpacing.s24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: NileTextStyles.bodyMd(),
          ),
          if (action != null) ...[
            const SizedBox(height: NileSpacing.s16),
            FilledButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    ),
  );
}

/// Plays the signed HLS stream so the host can check the upload.
class _PreviewDialog extends StatefulWidget {
  const _PreviewDialog({required this.url});

  final Uri url;

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  late final VideoPlayerController _c = VideoPlayerController.networkUrl(
    widget.url,
  );
  String? _error;

  @override
  void initState() {
    super.initState();
    _c
        .initialize()
        .then((_) {
          if (mounted) setState(() {});
          _c.play();
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = 'Couldn’t play the preview.');
        });
    _c.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.black,
    insetPadding: const EdgeInsets.all(NileSpacing.s16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: _c.value.isInitialized ? _c.value.aspectRatio : 16 / 9,
            child: _error != null
                ? Center(
                    child: Text(
                      _error!,
                      style: NileTextStyles.bodyMd().copyWith(
                        color: Colors.white,
                      ),
                    ),
                  )
                : _c.value.isInitialized
                ? VideoPlayer(_c)
                : const Center(child: CircularProgressIndicator()),
          ),
          if (_c.value.isInitialized)
            VideoProgressIndicator(
              _c,
              allowScrubbing: true,
              colors: VideoProgressColors(playedColor: NileColors.volt),
            ),
          Row(
            children: [
              IconButton(
                tooltip: _c.value.isPlaying ? 'Pause' : 'Play',
                color: Colors.white,
                onPressed: () => _c.value.isPlaying ? _c.pause() : _c.play(),
                icon: Icon(_c.value.isPlaying ? Icons.pause : Icons.play_arrow),
              ),
              Text(
                '${formatFilmLength(_c.value.position)} / '
                '${formatFilmLength(_c.value.duration)}',
                style: NileTextStyles.caption().copyWith(color: Colors.white),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
