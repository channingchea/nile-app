import 'dart:typed_data';

import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';

import '../services/post_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';

class CreatePostScreen extends StatefulWidget {
  /// Optional pre-filled caption (e.g. when posting about a new event).
  final String? initialText;

  /// Optional event to attach; renders as a thumbnail card on the post.
  final String? eventId;

  const CreatePostScreen({super.key, this.initialText, this.eventId});

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  final _captionController = TextEditingController();
  final List<Uint8List> _images = [];
  bool _pickingImage = false;
  bool _submitting = false;
  String? _errorMessage;

  static const int _maxCaption = 500;

  @override
  void initState() {
    super.initState();
    if (widget.initialText != null) {
      _captionController.text = widget.initialText!;
    }
    _captionController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  bool get _canPost {
    final hasCaption = _captionController.text.trim().isNotEmpty;
    return (hasCaption || _images.isNotEmpty) && !_submitting;
  }

  bool get _canAddImage => _images.length < PostService.maxImages;

  Future<void> _pickImage() async {
    if (!_canAddImage) return;
    setState(() => _pickingImage = true);
    try {
      final picked = await ProfileService.pickMultiImageBytes(
        context,
        maxWidth: 1600,
        maxHeight: 1200,
        limit: PostService.maxImages - _images.length,
        allowedAspectRatios: [const CropAspectRatio(width: 4, height: 3)],
      );
      if (picked.isNotEmpty && mounted) setState(() => _images.addAll(picked));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  Future<void> _submit() async {
    if (!_canPost) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      List<String> imageUrls = const [];
      if (_images.isNotEmpty) {
        try {
          imageUrls = await PostService.uploadImagesBytes(_images);
        } catch (e) {
          // Non-fatal if caption is present — fall back to text-only.
          if (_captionController.text.trim().isEmpty) {
            rethrow; // No caption, no images → can't post.
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Image upload failed — posted text only. ($e)'),
              ),
            );
          }
        }
      }

      final post = await PostService.create(
        content: _captionController.text,
        imageUrls: imageUrls,
        eventId: widget.eventId,
      );

      if (!mounted) return;
      Navigator.pop(context, post);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to post: $e';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Text('New Post', style: NileTextStyles.headingMd()),
        backgroundColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: NileSpacing.s12, top: NileSpacing.s8, bottom: NileSpacing.s8),
            child: FilledButton(
              onPressed: _canPost ? _submit : null,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
                disabledBackgroundColor: NileColors.bgRaised,
                disabledForegroundColor: NileColors.txtTertiary,
                padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
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
        child: AbsorbPointer(
          absorbing: _submitting,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s8, NileSpacing.s16, NileSpacing.s40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _captionController,
                  maxLines: 6,
                  minLines: 4,
                  maxLength: _maxCaption,
                  textCapitalization: TextCapitalization.sentences,
                  style: NileTextStyles.bodyLg(),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    hintText: "What's on your mind?",
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
                if (_images.isNotEmpty)
                  _ImageStrip(
                    images: _images,
                    canAdd: _canAddImage,
                    busy: _pickingImage,
                    onAdd: _pickImage,
                    onRemove: (i) => setState(() => _images.removeAt(i)),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _pickingImage ? null : _pickImage,
                    icon: _pickingImage
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: NileColors.volt,
                            ),
                          )
                        : const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(_pickingImage ? 'Loading…' : 'Add photo'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                      side: BorderSide(color: NileColors.border),
                    ),
                  ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(NileSpacing.s12),
                    decoration: BoxDecoration(
                      color: NileColors.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(NileRadius.sm),
                      border: Border.all(
                        color: NileColors.error.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${_captionController.text.length}/$_maxCaption',
                    style: NileTextStyles.caption(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal strip of selected images (square thumbs) with per-image remove
/// and a trailing add tile while under the [PostService.maxImages] cap.
class _ImageStrip extends StatelessWidget {
  final List<Uint8List> images;
  final bool canAdd;
  final bool busy;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  const _ImageStrip({
    required this.images,
    required this.canAdd,
    required this.busy,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: images.length + (canAdd ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(width: NileSpacing.s8),
            itemBuilder: (_, i) {
              if (i == images.length) return _addTile();
              return _thumb(images[i], i);
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${images.length}/${PostService.maxImages} photos',
          style: NileTextStyles.caption(),
        ),
      ],
    );
  }

  Widget _thumb(Uint8List bytes, int index) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Stack(
        children: [
          Image.memory(bytes, width: 96, height: 96, fit: BoxFit.cover, cacheWidth: nileDecodeWidth(96)),
          Positioned(
            top: 2,
            right: 2,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.close, size: 16, color: Colors.white),
                onPressed: () => onRemove(index),
                tooltip: 'Remove photo',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _addTile() {
    return InkWell(
      onTap: busy ? null : onAdd,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(NileRadius.sm),
          border: Border.all(color: NileColors.border),
        ),
        child: Center(
          child: busy
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NileColors.volt,
                  ),
                )
              : Icon(
                  Icons.add_photo_alternate_outlined,
                  color: NileColors.txtTertiary,
                ),
        ),
      ),
    );
  }
}
