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
  Uint8List? _imageBytes;
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
    return (hasCaption || _imageBytes != null) && !_submitting;
  }

  Future<void> _pickImage() async {
    setState(() => _pickingImage = true);
    try {
      final bytes = await ProfileService.pickImageBytes(
        context,
        maxWidth: 1600,
        maxHeight: 1200,
        allowedAspectRatios: [const CropAspectRatio(width: 4, height: 3)],
      );
      if (bytes != null && mounted) setState(() => _imageBytes = bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
      String? imageUrl;
      if (_imageBytes != null) {
        try {
          imageUrl = await PostService.uploadImageBytes(_imageBytes!);
        } catch (e) {
          // Non-fatal if caption is present — fall back to text-only.
          if (_captionController.text.trim().isEmpty) {
            rethrow; // No caption, no image → can't post.
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Image upload failed — posted text only. ($e)')),
            );
          }
        }
      }

      final post = await PostService.create(
        content: _captionController.text,
        imageUrl: imageUrl,
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
            padding: const EdgeInsets.only(right: 12, top: 8, bottom: 8),
            child: FilledButton(
              onPressed: _canPost ? _submit : null,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.bgPage,
                disabledBackgroundColor: NileColors.bgRaised,
                disabledForegroundColor: NileColors.txtTertiary,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: NileColors.bgPage),
                    )
                  : const Text('Post'),
            ),
          ),
        ],
      ),
      body: NileMaxWidth(child: AbsorbPointer(
        absorbing: _submitting,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
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
              if (_imageBytes != null)
                _ImagePreview(
                  bytes: _imageBytes!,
                  onRemove: () => setState(() => _imageBytes = null),
                ),
              if (_imageBytes == null)
                OutlinedButton.icon(
                  onPressed: _pickingImage ? null : _pickImage,
                  icon: _pickingImage
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: NileColors.volt),
                        )
                      : const Icon(Icons.add_photo_alternate_outlined),
                  label: Text(_pickingImage ? 'Loading…' : 'Add photo'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: NileColors.border),
                  ),
                ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: NileColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(NileRadius.sm),
                    border:
                        Border.all(color: NileColors.error.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: NileTextStyles.bodySm()
                        .copyWith(color: NileColors.error),
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
      )),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final Uint8List bytes;
  final VoidCallback onRemove;
  const _ImagePreview({required this.bytes, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.md),
      child: Stack(
        children: [
          Image.memory(bytes, fit: BoxFit.cover, width: double.infinity),
          Positioned(
            top: 8,
            right: 8,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: IconButton(
                icon: const Icon(Icons.close, size: 18, color: Colors.white),
                onPressed: onRemove,
                tooltip: 'Remove photo',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
