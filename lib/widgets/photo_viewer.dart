import 'package:flutter/material.dart';

import '../theme.dart';

/// Full-screen photo viewer: black backdrop, pinch-to-zoom, tap anywhere (or
/// the close button / back gesture) to dismiss. Supports a single image or a
/// swipeable gallery (multi-image posts) with a position badge. Pass [heroTag]
/// matching the thumbnail's Hero so the photo expands from where it was tapped
/// (applied to the initially-shown image only).
class PhotoViewerScreen extends StatefulWidget {
  final List<ImageProvider> images;
  final int initialIndex;
  final Object? heroTag;

  const PhotoViewerScreen({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.heroTag,
  });

  /// Single image (profile avatar / cover photo).
  static Future<void> open(
    BuildContext context, {
    required ImageProvider image,
    Object? heroTag,
  }) =>
      openGallery(context, images: [image], heroTag: heroTag);

  /// Multiple images (post carousels), starting at [initialIndex].
  static Future<void> openGallery(
    BuildContext context, {
    required List<ImageProvider> images,
    int initialIndex = 0,
    Object? heroTag,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) => PhotoViewerScreen(
          images: images,
          initialIndex: initialIndex,
          heroTag: heroTag,
        ),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _photo(int i) {
    Widget photo = Image(
      image: widget.images[i],
      fit: BoxFit.contain,
      loadingBuilder: (_, child, progress) => progress == null
          ? child
          : const Center(
              child: CircularProgressIndicator(color: Colors.white54),
            ),
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.broken_image_outlined,
            color: Colors.white38, size: 48),
      ),
    );
    if (widget.heroTag != null && i == widget.initialIndex) {
      photo = Hero(tag: widget.heroTag!, child: photo);
    }
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: InteractiveViewer(
        maxScale: 4,
        child: Center(child: photo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final many = widget.images.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (many)
            PageView.builder(
              controller: _controller,
              itemCount: widget.images.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => _photo(i),
            )
          else
            _photo(0),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black45,
              ),
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          if (many)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s8,
                  vertical: NileSpacing.s2,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
                child: Text(
                  '${_index + 1}/${widget.images.length}',
                  style: NileTextStyles.caption().copyWith(color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
