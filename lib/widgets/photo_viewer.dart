import 'package:flutter/material.dart';

/// Full-screen photo viewer: black backdrop, pinch-to-zoom, tap anywhere (or
/// the close button / back gesture) to dismiss. Pass [heroTag] matching the
/// thumbnail's Hero so the photo expands from where it was tapped.
class PhotoViewerScreen extends StatelessWidget {
  final ImageProvider image;
  final Object? heroTag;

  const PhotoViewerScreen({super.key, required this.image, this.heroTag});

  static Future<void> open(
    BuildContext context, {
    required ImageProvider image,
    Object? heroTag,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) =>
            PhotoViewerScreen(image: image, heroTag: heroTag),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget photo = Image(
      image: image,
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
    if (heroTag != null) photo = Hero(tag: heroTag!, child: photo);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: InteractiveViewer(
              maxScale: 4,
              child: Center(child: photo),
            ),
          ),
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
        ],
      ),
    );
  }
}
