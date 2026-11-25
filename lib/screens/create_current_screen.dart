import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../services/current_service.dart';
import '../theme.dart';

/// Create a Current: record with the camera or pick from the gallery, trim to
/// ≤60s on a visual timeline, caption, post. Trimming + 720p compression run
/// on-device via video_compress (native encoders — no ffmpeg dependency).
class CreateCurrentScreen extends StatefulWidget {
  const CreateCurrentScreen({super.key});

  @override
  State<CreateCurrentScreen> createState() => _CreateCurrentScreenState();
}

class _CreateCurrentScreenState extends State<CreateCurrentScreen> {
  final _picker = ImagePicker();
  final _captionController = TextEditingController();

  File? _video;
  VideoPlayerController? _player;
  List<Uint8List> _stripFrames = [];

  // Image-slideshow mode: non-empty means the user is building an image Current.
  final List<_ImageDraft> _images = [];
  bool get _isImageMode => _images.isNotEmpty;
  static const int _defaultImageMs = 4000;

  // Trim window, ms.
  int _videoMs = 0;
  int _startMs = 0;
  int _endMs = 0;

  bool _picking = false;
  bool _submitting = false;
  double _compressProgress = 0;
  String? _stage; // 'Compressing…' / 'Uploading…'
  String? _errorMessage;
  Subscription? _compressSub;

  static const int _maxMs = CurrentService.maxDurationMs;
  static const int _minMs = 1000;
  static const int _stripFrameCount = 8;

  /// Encode ladder, tried in order until the output fits the upload cap.
  static const _qualitySteps = [
    VideoQuality.Res1280x720Quality,
    VideoQuality.Res960x540Quality,
    VideoQuality.Res640x480Quality,
  ];

  @override
  void dispose() {
    _captionController.dispose();
    _player?.dispose();
    _compressSub?.unsubscribe();
    super.dispose();
  }

  int get _spanMs => _endMs - _startMs;

  // ── Pick / record ──────────────────────────────────────────────────────────

  Future<void> _pick(ImageSource source) async {
    // image_picker only backs the camera on iOS/Android. On desktop/web it
    // throws a raw "cameraDelegate" error, so steer to the gallery instead.
    if (source == ImageSource.camera &&
        !(Platform.isIOS || Platform.isAndroid)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recording is only available in the mobile app — '
              'choose a video from your gallery instead.'),
        ),
      );
      return;
    }
    setState(() => _picking = true);
    try {
      final picked = await _picker.pickVideo(
        source: source,
        // The system camera enforces the cap at record time; gallery videos
        // longer than 60s are trimmed below.
        maxDuration: source == ImageSource.camera
            ? const Duration(seconds: 60)
            : null,
      );
      if (picked == null) return;
      await _load(File(picked.path));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pickImages({bool append = false}) async {
    setState(() => _picking = true);
    try {
      // Downscale on pick: a full-res phone photo is 3–8 MB, and 20 of them
      // blow past the upload cap. 1920px/85% keeps each frame a few hundred KB.
      final picked = await _picker.pickMultiImage(
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (picked.isEmpty) return;
      final room = CurrentService.maxImages - (append ? _images.length : 0);
      final drafts = picked
          .take(room < 0 ? 0 : room)
          .map((x) => _ImageDraft(File(x.path), _defaultImageMs))
          .toList();
      setState(() {
        if (!append) _images.clear();
        _images.addAll(drafts);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  int get _imagesTotalMs => _images.fold(0, (s, d) => s + d.durationMs);

  Future<void> _load(File video) async {
    await _player?.dispose();
    final player = VideoPlayerController.file(video);
    await player.initialize();
    final ms = player.value.duration.inMilliseconds;
    if (ms < _minMs) {
      await player.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That video is too short.')),
        );
      }
      return;
    }
    player
      ..setLooping(false)
      ..addListener(_loopWithinTrim)
      ..play();
    setState(() {
      _video = video;
      _player = player;
      _videoMs = ms;
      _startMs = 0;
      _endMs = ms.clamp(0, _maxMs);
      _stripFrames = [];
    });
    _buildStrip(video.path, ms);
  }

  /// Preview playback loops inside the trim window.
  void _loopWithinTrim() {
    final p = _player;
    if (p == null || !p.value.isPlaying) return;
    final pos = p.value.position.inMilliseconds;
    if (pos >= _endMs || pos < _startMs - 500) {
      p.seekTo(Duration(milliseconds: _startMs));
    }
  }

  Future<void> _buildStrip(String path, int ms) async {
    final frames = <Uint8List>[];
    for (var i = 0; i < _stripFrameCount; i++) {
      try {
        final f = await VideoThumbnail.thumbnailData(
          video: path,
          timeMs: (ms * i) ~/ _stripFrameCount,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 120,
          quality: 50,
        );
        if (f != null) frames.add(f);
      } catch (_) {}
      if (!mounted) return;
    }
    if (mounted) setState(() => _stripFrames = frames);
  }

  void _onTrimChanged(int startMs, int endMs) {
    setState(() {
      _startMs = startMs;
      _endMs = endMs;
    });
    _player?.seekTo(Duration(milliseconds: startMs));
  }

  // ── Submit ─────────────────────────────────────────────────────────────────

  bool get _canPost {
    if (_submitting) return false;
    if (_isImageMode) {
      return _imagesTotalMs <= _maxMs && _imagesTotalMs > 0;
    }
    return _video != null && _spanMs >= _minMs;
  }

  Future<void> _submitImages() async {
    if (!_canPost) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
      _stage = 'Uploading…';
    });
    try {
      final current = await CurrentService.createImages(
        images: [for (final d in _images) (file: d.file, durationMs: d.durationMs)],
        caption: _captionController.text,
      );
      if (!mounted) return;
      Navigator.pop(context, current);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _friendlyError(e);
        _submitting = false;
        _stage = null;
      });
    }
  }

  /// Storage's 413 reads as a raw StorageException — say something useful.
  String _friendlyError(Object e) {
    if (e is _TooLarge) return e.message;
    final s = e.toString();
    if (s.contains('413') ||
        s.contains('exceeded the maximum allowed size') ||
        s.toLowerCase().contains('payload too large')) {
      return _isImageMode
          ? 'These images are too large to upload. Try posting fewer of them.'
          : 'This video is too large to upload. Try trimming it shorter.';
    }
    return 'Failed to post: $e';
  }

  Future<void> _submit() async {
    if (!_canPost) return;
    if (_isImageMode) return _submitImages();
    setState(() {
      _submitting = true;
      _errorMessage = null;
      _stage = 'Compressing…';
      _compressProgress = 0;
    });
    _player?.pause();

    try {
      _compressSub = VideoCompress.compressProgress$.subscribe((p) {
        if (mounted) setState(() => _compressProgress = p / 100);
      });

      final needsTrim = _startMs > 0 || _endMs < _videoMs;
      // Encode at 720p, then step down until the result fits the upload cap.
      // A high-bitrate 4K source can survive a 720p export well over 50 MB —
      // and video_compress hands back the original when it can't encode at all.
      File? out;
      int outMs = 0;
      for (final q in _qualitySteps) {
        if (q != _qualitySteps.first && mounted) {
          setState(() {
            _stage = 'Compressing… (reducing quality)';
            _compressProgress = 0;
          });
        }
        final info = await VideoCompress.compressVideo(
          _video!.path,
          quality: q,
          deleteOrigin: false,
          includeAudio: true,
          startTime: needsTrim ? _startMs ~/ 1000 : null,
          duration: needsTrim ? (_spanMs / 1000).ceil() : null,
        );
        final f = info?.file;
        if (f == null) throw StateError('Video processing failed.');
        if (await f.length() <= CurrentService.maxUploadBytes) {
          out = f;
          outMs = (info!.duration ?? _spanMs.toDouble()).round();
          break;
        }
      }
      _compressSub?.unsubscribe();
      _compressSub = null;
      if (out == null) {
        throw const _TooLarge(
            'This video is too large to post even at reduced quality. '
            'Try trimming it shorter.');
      }

      // Poster frame from the trim start.
      Uint8List? thumb;
      try {
        thumb = await VideoThumbnail.thumbnailData(
          video: out.path,
          timeMs: 0,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 720,
          quality: 75,
        );
      } catch (_) {}

      if (mounted) setState(() => _stage = 'Uploading…');
      final current = await CurrentService.create(
        video: out,
        thumbnail: thumb,
        caption: _captionController.text,
        durationMs: outMs.clamp(_minMs, _maxMs + 1000),
      );

      if (!mounted) return;
      Navigator.pop(context, current);
    } catch (e) {
      _compressSub?.unsubscribe();
      _compressSub = null;
      if (!mounted) return;
      setState(() {
        _errorMessage = _friendlyError(e);
        _submitting = false;
        _stage = null;
      });
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Text('New Current', style: NileTextStyles.headingMd()),
        backgroundColor: Colors.transparent,
        actions: [
          if (_video != null || _isImageMode)
            Padding(
              padding: const EdgeInsets.only(
                  right: NileSpacing.s12,
                  top: NileSpacing.s8,
                  bottom: NileSpacing.s8),
              child: FilledButton(
                onPressed: _canPost ? _submit : null,
                style: FilledButton.styleFrom(
                  backgroundColor: NileColors.volt,
                  foregroundColor: NileColors.onVolt,
                  disabledBackgroundColor: NileColors.bgRaised,
                  disabledForegroundColor: NileColors.txtTertiary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(NileRadius.pill),
                  ),
                ),
                child: _submitting
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NileColors.onVolt,
                        ),
                      )
                    : const Text('Post'),
              ),
            ),
        ],
      ),
      body: NileMaxWidth(
        child: _isImageMode
            ? _imageEditor()
            : _video == null
                ? _pickBody()
                : _trimBody(),
      ),
    );
  }

  Widget _pickBody() {
    return Padding(
      padding: const EdgeInsets.all(NileSpacing.s16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.bolt, size: 56, color: NileColors.volt),
          const SizedBox(height: NileSpacing.s12),
          Text(
            'Share a Current',
            textAlign: TextAlign.center,
            style: NileTextStyles.headingLg(),
          ),
          const SizedBox(height: NileSpacing.s8),
          Text(
            'A quick video or photo slideshow up to 60 seconds. '
            'It stays up for 24 hours.',
            textAlign: TextAlign.center,
            style: NileTextStyles.bodyMd()
                .copyWith(color: NileColors.txtSecondary),
          ),
          const SizedBox(height: NileSpacing.s32),
          FilledButton.icon(
            onPressed: _picking ? null : () => _pick(ImageSource.camera),
            icon: const Icon(Icons.videocam_outlined),
            label: const Text('Record'),
            style: FilledButton.styleFrom(
              backgroundColor: NileColors.volt,
              foregroundColor: NileColors.onVolt,
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
            ),
          ),
          const SizedBox(height: NileSpacing.s12),
          OutlinedButton.icon(
            onPressed: _picking ? null : () => _pick(ImageSource.gallery),
            icon: _picking
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: NileColors.volt),
                  )
                : const Icon(Icons.video_library_outlined),
            label: Text(_picking ? 'Loading…' : 'Choose video from gallery'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
              side: BorderSide(color: NileColors.border),
            ),
          ),
          const SizedBox(height: NileSpacing.s12),
          OutlinedButton.icon(
            onPressed: _picking ? null : () => _pickImages(),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Add photos'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
              side: BorderSide(color: NileColors.border),
            ),
          ),
        ],
      ),
    );
  }

  // ── Image editor ────────────────────────────────────────────────────────────

  Widget _imageEditor() {
    final totalS = _imagesTotalMs / 1000;
    final over = _imagesTotalMs > _maxMs;
    return AbsorbPointer(
      absorbing: _submitting,
      child: Column(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(NileSpacing.s16,
                  NileSpacing.s16, NileSpacing.s16, NileSpacing.s8),
              itemCount: _images.length,
              onReorderItem: (oldI, newI) => setState(() {
                _images.insert(newI, _images.removeAt(oldI));
              }),
              itemBuilder: (_, i) => _imageRow(i),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s16, vertical: NileSpacing.s4),
            child: Row(
              children: [
                Text(
                  '${totalS.toStringAsFixed(1)}s total',
                  style: NileTextStyles.caption()
                      .copyWith(color: over ? NileColors.error : null)
                      .tabular,
                ),
                const Spacer(),
                if (over)
                  Text('Max 60s',
                      style: NileTextStyles.caption()
                          .copyWith(color: NileColors.error)),
                if (!over && _images.length < CurrentService.maxImages)
                  TextButton.icon(
                    onPressed: _picking ? null : () => _pickImages(append: true),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add more'),
                    style: TextButton.styleFrom(
                        foregroundColor: NileColors.volt),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                NileSpacing.s16, 0, NileSpacing.s16, NileSpacing.s8),
            child: TextField(
              controller: _captionController,
              maxLength: CurrentService.maxCaption,
              maxLines: 2,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              style: NileTextStyles.bodyMd(),
              decoration: const InputDecoration(
                hintText: 'Add a caption…',
                counterText: '',
              ),
            ),
          ),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  NileSpacing.s16, 0, NileSpacing.s16, NileSpacing.s8),
              child: Text(
                _errorMessage!,
                style:
                    NileTextStyles.bodySm().copyWith(color: NileColors.error),
              ),
            ),
          SizedBox(
              height: MediaQuery.of(context).padding.bottom + NileSpacing.s8),
        ],
      ),
    );
  }

  Widget _imageRow(int i) {
    final d = _images[i];
    return Padding(
      key: ValueKey(d.file.path),
      padding: const EdgeInsets.only(bottom: NileSpacing.s12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(NileRadius.sm),
            child: Image.file(d.file,
                width: 44, height: 60, fit: BoxFit.cover),
          ),
          const SizedBox(width: NileSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${(d.durationMs / 1000).round()}s',
                    style: NileTextStyles.labelMd().tabular),
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 2,
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: (d.durationMs / 1000).toDouble(),
                    min: CurrentService.minImageMs / 1000,
                    max: CurrentService.maxImageMs / 1000,
                    divisions: (CurrentService.maxImageMs - CurrentService.minImageMs)
                        ~/ 1000,
                    activeColor: NileColors.volt,
                    onChanged: (v) =>
                        setState(() => d.durationMs = v.round() * 1000),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove this photo',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _images.removeAt(i)),
            icon: Icon(Icons.close, size: 18, color: NileColors.txtTertiary),
          ),
          ReorderableDragStartListener(
            index: i,
            child: Icon(Icons.drag_handle, color: NileColors.txtTertiary),
          ),
        ],
      ),
    );
  }

  Widget _trimBody() {
    final player = _player!;
    return AbsorbPointer(
      absorbing: _submitting,
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(NileRadius.lg),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: Colors.black),
                    Center(
                      child: AspectRatio(
                        aspectRatio: player.value.aspectRatio,
                        child: VideoPlayer(player),
                      ),
                    ),
                    // Tap to play/pause.
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() {
                          player.value.isPlaying
                              ? player.pause()
                              : player.play();
                        }),
                        child: AnimatedOpacity(
                          opacity: player.value.isPlaying ? 0 : 1,
                          duration: NileMotion.fast,
                          child: const Center(
                            child: Icon(Icons.play_arrow_rounded,
                                size: 64, color: Colors.white70),
                          ),
                        ),
                      ),
                    ),
                    if (_submitting)
                      Container(
                        color: Colors.black54,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 160,
                                child: LinearProgressIndicator(
                                  value: _stage == 'Compressing…'
                                      ? _compressProgress
                                      : null,
                                  color: NileColors.volt,
                                  backgroundColor: Colors.white24,
                                ),
                              ),
                              const SizedBox(height: NileSpacing.s12),
                              Text(
                                _stage ?? '',
                                style: NileTextStyles.bodyMd()
                                    .copyWith(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: NileSpacing.s12),
          _TrimBar(
            frames: _stripFrames,
            videoMs: _videoMs,
            startMs: _startMs,
            endMs: _endMs,
            maxSpanMs: _maxMs,
            minSpanMs: _minMs,
            onChanged: _onTrimChanged,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s16, vertical: NileSpacing.s4),
            child: Row(
              children: [
                Text(
                  '${(_spanMs / 1000).toStringAsFixed(1)}s selected',
                  style: NileTextStyles.caption().tabular,
                ),
                const Spacer(),
                if (_videoMs > _maxMs)
                  Text('Max 60s',
                      style: NileTextStyles.caption()
                          .copyWith(color: NileColors.txtTertiary)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                NileSpacing.s16, 0, NileSpacing.s16, NileSpacing.s8),
            child: TextField(
              controller: _captionController,
              maxLength: CurrentService.maxCaption,
              maxLines: 2,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              style: NileTextStyles.bodyMd(),
              decoration: const InputDecoration(
                hintText: 'Add a caption…',
                counterText: '',
              ),
            ),
          ),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  NileSpacing.s16, 0, NileSpacing.s16, NileSpacing.s8),
              child: Text(
                _errorMessage!,
                style:
                    NileTextStyles.bodySm().copyWith(color: NileColors.error),
              ),
            ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + NileSpacing.s8),
        ],
      ),
    );
  }
}

// ── Trim bar ──────────────────────────────────────────────────────────────────

/// Thumbnail filmstrip with draggable start/end handles. The selected window
/// is clamped to [minSpanMs, maxSpanMs].
class _TrimBar extends StatelessWidget {
  final List<Uint8List> frames;
  final int videoMs;
  final int startMs;
  final int endMs;
  final int maxSpanMs;
  final int minSpanMs;
  final void Function(int startMs, int endMs) onChanged;

  const _TrimBar({
    required this.frames,
    required this.videoMs,
    required this.startMs,
    required this.endMs,
    required this.maxSpanMs,
    required this.minSpanMs,
    required this.onChanged,
  });

  static const double _height = 56;
  static const double _handleW = 20;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final trackW = w - _handleW * 2;
          double msToX(int ms) => _handleW + trackW * ms / videoMs;
          int xToMs(double x) =>
              ((x - _handleW) / trackW * videoMs).round().clamp(0, videoMs);

          final startX = msToX(startMs);
          final endX = msToX(endMs);

          return SizedBox(
            height: _height,
            child: Stack(
              children: [
                // Filmstrip.
                Positioned.fill(
                  left: _handleW,
                  right: _handleW,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(NileRadius.sm),
                    child: frames.isEmpty
                        ? Container(color: NileColors.bgRaised)
                        : Row(
                            children: [
                              for (final f in frames)
                                Expanded(
                                  child: Image.memory(
                                    f,
                                    height: _height,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
                // Dimmed outside the window.
                Positioned(
                  left: _handleW,
                  width: (startX - _handleW).clamp(0, trackW),
                  top: 0,
                  bottom: 0,
                  child: Container(color: Colors.black54),
                ),
                Positioned(
                  left: endX,
                  width: (w - _handleW - endX).clamp(0, trackW),
                  top: 0,
                  bottom: 0,
                  child: Container(color: Colors.black54),
                ),
                // Window border.
                Positioned(
                  left: startX - 2,
                  width: (endX - startX) + 4,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.symmetric(
                          horizontal:
                              BorderSide(color: NileColors.volt, width: 2),
                        ),
                      ),
                    ),
                  ),
                ),
                // Start handle.
                _handle(
                  left: startX - _handleW,
                  icon: Icons.chevron_left,
                  onDrag: (dx, localX) {
                    var ms = xToMs(localX);
                    ms = ms.clamp(
                      (endMs - maxSpanMs).clamp(0, videoMs),
                      endMs - minSpanMs,
                    );
                    onChanged(ms, endMs);
                  },
                ),
                // End handle.
                _handle(
                  left: endX,
                  icon: Icons.chevron_right,
                  onDrag: (dx, localX) {
                    var ms = xToMs(localX);
                    ms = ms.clamp(
                      startMs + minSpanMs,
                      (startMs + maxSpanMs).clamp(0, videoMs),
                    );
                    onChanged(startMs, ms);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _handle({
    required double left,
    required IconData icon,
    required void Function(double dx, double localX) onDrag,
  }) {
    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: _handleW,
      child: Builder(
        builder: (context) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) {
            final box = context.findRenderObject() as RenderBox?;
            final parent = box?.parent;
            if (box == null || parent is! RenderBox) return;
            final localX =
                parent.globalToLocal(d.globalPosition).dx;
            onDrag(d.delta.dx, localX);
          },
          child: Container(
            decoration: BoxDecoration(
              color: NileColors.volt,
              borderRadius: BorderRadius.horizontal(
                left: icon == Icons.chevron_left
                    ? const Radius.circular(NileRadius.sm)
                    : Radius.zero,
                right: icon == Icons.chevron_right
                    ? const Radius.circular(NileRadius.sm)
                    : Radius.zero,
              ),
            ),
            child: Icon(icon, size: 16, color: NileColors.onVolt),
          ),
        ),
      ),
    );
  }
}

/// A pending slideshow image + its chosen on-screen duration (2–10s).
class _ImageDraft {
  final File file;
  int durationMs;
  _ImageDraft(this.file, this.durationMs);
}

/// Raised when even the lowest encode still exceeds the upload cap; carries
/// the message shown to the user verbatim.
class _TooLarge implements Exception {
  final String message;
  const _TooLarge(this.message);
  @override
  String toString() => message;
}
