import 'package:flutter/material.dart';

import '../theme.dart';

/// Swipeable 4:3 image carousel for posts. Renders a single image inline when
/// there's only one; shows page dots + a count badge for multiple. Used by both
/// the feed card and post detail.
class PostImageCarousel extends StatefulWidget {
  final List<String> imageUrls;
  final double decodeWidth;

  const PostImageCarousel({
    super.key,
    required this.imageUrls,
    this.decodeWidth = 600,
  });

  @override
  State<PostImageCarousel> createState() => _PostImageCarouselState();
}

class _PostImageCarouselState extends State<PostImageCarousel> {
  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final urls = widget.imageUrls;
    return ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (urls.length == 1)
              _image(urls.first)
            else
              PageView.builder(
                controller: _controller,
                itemCount: urls.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) => _image(urls[i]),
              ),
            if (urls.length > 1) ...[
              Positioned(
                top: NileSpacing.s8,
                right: NileSpacing.s8,
                child: _CountBadge(current: _index + 1, total: urls.length),
              ),
              Positioned(
                bottom: NileSpacing.s8,
                left: 0,
                right: 0,
                child: _Dots(count: urls.length, active: _index),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _image(String url) => Image.network(
    url,
    cacheWidth: nileDecodeWidth(widget.decodeWidth),
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => Container(
      color: NileColors.bgRaised,
      child: const Center(
        child: Icon(Icons.broken_image, color: NileColors.border),
      ),
    ),
  );
}

class _CountBadge extends StatelessWidget {
  final int current;
  final int total;
  const _CountBadge({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s8,
        vertical: NileSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Text(
        '$current/$total',
        style: NileTextStyles.caption().copyWith(color: Colors.white),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int active;
  const _Dots({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final on = i == active;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: on ? 8 : 6,
          height: on ? 8 : 6,
          decoration: BoxDecoration(
            color: on ? NileColors.volt : Colors.white70,
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }
}
