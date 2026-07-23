import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/rapid_service.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/nile_glass_app_bar.dart';

/// The caller's own Rapids, newest first, including expired ones (the 24h
/// public window hides them everywhere else; storage purges ~30 days after
/// expiry). Tap to replay; overflow to delete.
class MyRapidsScreen extends StatefulWidget {
  const MyRapidsScreen({super.key});

  @override
  State<MyRapidsScreen> createState() => _MyRapidsScreenState();
}

class _MyRapidsScreenState extends State<MyRapidsScreen> {
  List<Rapid>? _rapids;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _rapids = null;
      _error = null;
    });
    try {
      final rows = await RapidService.myArchive();
      if (mounted) setState(() => _rapids = rows);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _delete(Rapid r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Delete this Rapid?', style: NileTextStyles.headingSm()),
        content: Text(
          'The video and its likes, comments, and views are removed permanently.',
          style: NileTextStyles.bodySm(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: NileColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await RapidService.delete(r);
      if (mounted) setState(() => _rapids!.removeWhere((x) => x.id == r.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Couldn\'t delete: $e')));
      }
    }
  }

  void _play(Rapid r) {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _ArchivePlayer(rapid: r),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight;
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      extendBodyBehindAppBar: true,
      appBar: NileGlassBar.appBar(title: const Text('My Rapids')),
      body: NileMaxWidth(
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(NileSpacing.s24),
                  child: Text(_error!,
                      style: NileTextStyles.bodyMd()
                          .copyWith(color: NileColors.error)),
                ),
              )
            : _rapids == null
                ? Center(
                    child: CircularProgressIndicator(color: NileColors.volt))
                : _rapids!.isEmpty
                    ? const NileEmptyState(
                        icon: Icons.bolt,
                        title: 'No Rapids yet',
                        body:
                            'Rapids you post appear here, including ones that '
                            'have expired from the rail.',
                      )
                    : RefreshIndicator(
                        color: NileColors.volt,
                        backgroundColor: NileColors.bgSurface,
                        onRefresh: _load,
                        child: GridView.builder(
                          padding: EdgeInsets.fromLTRB(
                              NileSpacing.s16,
                              topInset + NileSpacing.s16,
                              NileSpacing.s16,
                              NileSpacing.s32),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: NileSpacing.s8,
                            crossAxisSpacing: NileSpacing.s8,
                            childAspectRatio: 9 / 16,
                          ),
                          itemCount: _rapids!.length,
                          itemBuilder: (_, i) => _tile(_rapids![i]),
                        ),
                      ),
      ),
    );
  }

  Widget _tile(Rapid r) {
    return GestureDetector(
      onTap: () => _play(r),
      onLongPress: () => _delete(r),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(NileRadius.md),
        child: Stack(
          fit: StackFit.expand,
          children: [
            r.thumbUrl != null
                ? Image.network(
                    r.thumbUrl!,
                    fit: BoxFit.cover,
                    cacheWidth: nileDecodeWidth(200),
                    errorBuilder: (_, _, _) =>
                        ColoredBox(color: NileColors.bgRaised),
                  )
                : ColoredBox(color: NileColors.bgRaised),
            const DecoratedBox(decoration: NileEffects.coverScrim),
            Positioned(
              left: NileSpacing.s6,
              bottom: NileSpacing.s6,
              child: Row(
                children: [
                  const Icon(Icons.play_arrow, size: 14, color: Colors.white),
                  Text(
                    '${r.viewCount}',
                    style: NileTextStyles.caption()
                        .copyWith(color: Colors.white)
                        .tabular,
                  ),
                ],
              ),
            ),
            if (r.expired)
              Positioned(
                top: NileSpacing.s6,
                left: NileSpacing.s6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: NileSpacing.s6, vertical: NileSpacing.s2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(NileRadius.xs),
                  ),
                  child: Text(
                    'Expired',
                    style: NileTextStyles.caption()
                        .copyWith(color: Colors.white70),
                  ),
                ),
              ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => _delete(r),
                icon: const Icon(Icons.more_horiz,
                    size: 18, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Minimal single-video replay for the archive (loops; tap to pause).
class _ArchivePlayer extends StatefulWidget {
  final Rapid rapid;
  const _ArchivePlayer({required this.rapid});

  @override
  State<_ArchivePlayer> createState() => _ArchivePlayerState();
}

class _ArchivePlayerState extends State<_ArchivePlayer> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.rapid.videoUrl));
    _c = c;
    await c.initialize();
    if (!mounted) return;
    c
      ..setLooping(true)
      ..play();
    setState(() {});
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!ready) return;
          setState(() => c.value.isPlaying ? c.pause() : c.play());
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (ready)
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: c.value.size.width,
                  height: c.value.size.height,
                  child: VideoPlayer(c),
                ),
              )
            else
              Center(
                  child: CircularProgressIndicator(color: NileColors.volt)),
            if (ready && !c.value.isPlaying)
              const Center(
                child: Icon(Icons.play_arrow_rounded,
                    size: 72, color: Colors.white70),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
