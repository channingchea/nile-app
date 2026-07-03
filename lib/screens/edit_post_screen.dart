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

/// One slot in the edit screen's image set: either an already-uploaded [url]
/// or freshly-picked [bytes] awaiting upload.
class _ImageSlot {
  final String? url;
  final Uint8List? bytes;
  const _ImageSlot.existing(this.url) : bytes = null;
  const _ImageSlot.fresh(this.bytes) : url = null;
}

class _EditPostScreenState extends State<EditPostScreen> {
  late final TextEditingController _captionController;
  final List<_ImageSlot> _slots = [];
  bool _pickingImage = false;
  bool _saving = false;
  String? _error;

  static const int _maxCaption = 500;

  @override
  void initState() {
    super.initState();
    _captionController = TextEditingController(text: widget.post.content ?? '');
    _captionController.addListener(() => setState(() {}));
    _slots.addAll(widget.post.images.map(_ImageSlot.existing));
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  bool get _canAddImage => _slots.length < PostService.maxImages;

  bool get _canSave {
    final hasCaption = _captionController.text.trim().isNotEmpty;
    return (_slots.isNotEmpty || hasCaption) && !_saving;
  }

  Future<void> _pickImage() async {
    if (!_canAddImage) return;
    setState(() => _pickingImage = true);
    try {
      final picked = await ProfileService.pickMultiImageBytes(
        context,
        maxWidth: 1600,
        maxHeight: 1200,
        limit: PostService.maxImages - _slots.length,
        allowedAspectRatios: [const CropAspectRatio(width: 4, height: 3)],
      );
      if (picked.isNotEmpty && mounted) {
        setState(() => _slots.addAll(picked.map(_ImageSlot.fresh)));
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

  void _removeImage(int index) => setState(() => _slots.removeAt(index));

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      // Resolve each slot to a URL, uploading fresh bytes in order.
      final imageUrls = <String>[];
      for (final slot in _slots) {
        if (slot.url != null) {
          imageUrls.add(slot.url!);
        } else if (slot.bytes != null) {
          imageUrls.add(await PostService.uploadImageBytes(slot.bytes!));
        }
      }

      final caption = _captionController.text;
      final updated = await PostService.update(
        postId: widget.post.id,
        content: caption != (widget.post.content ?? '') ? caption : null,
        imageUrls: imageUrls,
        clearImage: imageUrls.isEmpty,
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
                if (_slots.isNotEmpty)
                  _ImageStrip(
                    slots: _slots,
                    canAdd: _canAddImage,
                    busy: _pickingImage,
                    onAdd: _pickImage,
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

// ── Image strip (existing + freshly-picked thumbs, remove + add tile) ─────────

class _ImageStrip extends StatelessWidget {
  final List<_ImageSlot> slots;
  final bool canAdd;
  final bool busy;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  const _ImageStrip({
    required this.slots,
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
            itemCount: slots.length + (canAdd ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(width: NileSpacing.s8),
            itemBuilder: (_, i) {
              if (i == slots.length) return _addTile();
              return _thumb(slots[i], i);
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${slots.length}/${PostService.maxImages} photos',
          style: NileTextStyles.caption(),
        ),
      ],
    );
  }

  Widget _thumb(_ImageSlot slot, int index) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Stack(
        children: [
          if (slot.bytes != null)
            Image.memory(slot.bytes!, width: 96, height: 96, fit: BoxFit.cover)
          else
            Image.network(
              slot.url!,
              width: 96,
              height: 96,
              fit: BoxFit.cover,
              cacheWidth: nileDecodeWidth(200),
            ),
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
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NileColors.volt,
                  ),
                )
              : const Icon(
                  Icons.add_photo_alternate_outlined,
                  color: NileColors.txtTertiary,
                ),
        ),
      ),
    );
  }
}
