import 'dart:typed_data';

import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';

import '../services/post_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';

/// Edit a post's caption and/or image. Pops with the updated [Post] on success.
class EditPostScreen extends StatefulWidget {
  final Post post;
  const EditPostScreen({super.key, required this.post});

  @override
  State<EditPostScreen> createState() => _EditPostScreenState();
}

class _EditPostScreenState extends State<EditPostScreen> {
  late final TextEditingController _captionController;
  Uint8List? _newImageBytes;
  String? _existingImageUrl;
  bool _imageCleared = false;
  bool _pickingImage = false;
  bool _saving = false;
  String? _error;

  static const int _maxCaption = 500;

  @override
  void initState() {
    super.initState();
    _captionController = TextEditingController(text: widget.post.content ?? '');
    _captionController.addListener(() => setState(() {}));
    _existingImageUrl = widget.post.imageUrl;
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  bool get _hasImage =>
      _newImageBytes != null || (_existingImageUrl != null && !_imageCleared);

  bool get _canSave {
    final hasCaption = _captionController.text.trim().isNotEmpty;
    return (_hasImage || hasCaption) && !_saving;
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
      if (bytes != null && mounted) {
        setState(() {
          _newImageBytes = bytes;
          _imageCleared = false;
        });
      }
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

  void _removeImage() => setState(() {
    _newImageBytes = null;
    _existingImageUrl = null;
    _imageCleared = true;
  });

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      String? newImageUrl;
      if (_newImageBytes != null) {
        try {
          newImageUrl = await PostService.uploadImageBytes(_newImageBytes!);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Image upload failed: $e')));
          }
        }
      }

      final caption = _captionController.text;
      final updated = await PostService.update(
        postId: widget.post.id,
        content: caption != (widget.post.content ?? '') ? caption : null,
        imageUrl: newImageUrl,
        clearImage: _imageCleared,
      );

      if (!mounted) return;
      Navigator.pop(context, updated);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Failed to save: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Text('Edit Post', style: NileTextStyles.headingMd()),
        backgroundColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: NileSpacing.s12, top: NileSpacing.s8, bottom: NileSpacing.s8),
            child: FilledButton(
              onPressed: _canSave ? _save : null,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.bgPage,
                disabledBackgroundColor: NileColors.bgRaised,
                disabledForegroundColor: NileColors.txtTertiary,
                padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: NileColors.bgPage,
                      ),
                    )
                  : Text('Save', style: NileTextStyles.labelMd()),
            ),
          ),
        ],
      ),
      body: NileMaxWidth(
        child: AbsorbPointer(
          absorbing: _saving,
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
                if (_hasImage)
                  _ImageEditor(
                    bytes: _newImageBytes,
                    url: _existingImageUrl,
                    busy: _pickingImage,
                    onReplace: _pickingImage ? null : _pickImage,
                    onRemove: _removeImage,
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _pickingImage ? null : _pickImage,
                    icon: _pickingImage
                        ? const SizedBox(
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
                      side: const BorderSide(color: NileColors.border),
                    ),
                  ),
                if (_error != null) ...[
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
                      _error!,
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

// ── Image editor (shows existing/new image with replace + remove controls) ────

class _ImageEditor extends StatelessWidget {
  final Uint8List? bytes;
  final String? url;
  final bool busy;
  final VoidCallback? onReplace;
  final VoidCallback onRemove;

  const _ImageEditor({
    required this.bytes,
    required this.url,
    required this.busy,
    required this.onReplace,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.md),
      child: Stack(
        children: [
          if (bytes != null)
            Image.memory(bytes!, fit: BoxFit.cover, width: double.infinity)
          else if (url != null)
            Image.network(url!, fit: BoxFit.cover, width: double.infinity, cacheWidth: nileDecodeWidth(600)),
          if (busy)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: const Center(
                  child: CircularProgressIndicator(color: NileColors.volt),
                ),
              ),
            ),
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
          if (!busy)
            Positioned(
              bottom: 8,
              right: 8,
              child: Material(
                color: Colors.black54,
                shape: const StadiumBorder(),
                child: InkWell(
                  onTap: onReplace,
                  customBorder: const StadiumBorder(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NileSpacing.s12,
                      vertical: NileSpacing.s6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.edit, size: 14, color: Colors.white),
                        const SizedBox(width: 4),
                        Text(
                          'Replace',
                          style: NileTextStyles.caption().copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
