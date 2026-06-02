import 'dart:typed_data';
import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import 'profile_screen.dart' show CoverPhoto, buildCameraChip;

class EditProfileScreen extends StatefulWidget {
  final UserProfile profile;

  const EditProfileScreen({super.key, required this.profile});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _displayNameCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _bioCtrl;

  // Avatar
  Uint8List? _localAvatarBytes;
  String? _remoteAvatarUrl;
  bool _uploadingAvatar = false;

  // Cover
  Uint8List? _localCoverBytes;
  String? _remoteCoverUrl;
  bool _uploadingCover = false;

  bool _saving = false;

  static const double _coverHeight = 160;
  static const double _avatarRadius = 44;

  @override
  void initState() {
    super.initState();
    _displayNameCtrl = TextEditingController(text: widget.profile.displayName);
    _usernameCtrl    = TextEditingController(text: widget.profile.username);
    _bioCtrl         = TextEditingController(text: widget.profile.bio ?? '');
    _remoteAvatarUrl = widget.profile.avatarUrl;
    _remoteCoverUrl  = widget.profile.coverUrl;
  }

  @override
  void dispose() {
    _displayNameCtrl.dispose();
    _usernameCtrl.dispose();
    _bioCtrl.dispose();
    super.dispose();
  }

  // ─── Pickers ──────────────────────────────────────────────────────────────

  Future<void> _pickAvatar() async {
    if (_uploadingAvatar) return;
    final Uint8List? bytes;
    try {
      bytes = await ProfileService.pickImageBytes(
        context,
        cropPathFn: ellipseCropShapeFn,
        allowedAspectRatios: [const CropAspectRatio(width: 1, height: 1)],
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (bytes == null) return;

    setState(() {
      _localAvatarBytes = bytes;
      _uploadingAvatar = true;
    });

    try {
      final url = await ProfileService.uploadAvatarBytes(widget.profile.id, bytes);
      if (mounted) setState(() { _remoteAvatarUrl = url; _uploadingAvatar = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _uploadingAvatar = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Avatar upload failed: $e')),
        );
      }
    }
  }

  Future<void> _pickCover() async {
    if (_uploadingCover) return;
    final Uint8List? bytes;
    try {
      bytes = await ProfileService.pickImageBytes(
        context,
        maxWidth: 1200,
        maxHeight: 600,
        allowedAspectRatios: [const CropAspectRatio(width: 15, height: 4)],
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (bytes == null) return;

    setState(() {
      _localCoverBytes = bytes;
      _uploadingCover = true;
    });

    try {
      final url = await ProfileService.uploadCoverBytes(widget.profile.id, bytes);
      if (mounted) setState(() { _remoteCoverUrl = url; _uploadingCover = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _uploadingCover = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cover upload failed: $e')),
        );
      }
    }
  }

  // ─── Save ─────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final updated = await ProfileService.updateProfile(
        userId: widget.profile.id,
        displayName: _displayNameCtrl.text.trim(),
        username: _usernameCtrl.text.trim(),
        bio: _bioCtrl.text.trim().isEmpty ? null : _bioCtrl.text.trim(),
      );
      // Carry over the latest image URLs (uploads happen eagerly, so the
      // returned profile row already has them, but copyWith is safe either way).
      final withImages = updated.copyWith(
        avatarUrl: _remoteAvatarUrl,
        coverUrl: _remoteCoverUrl,
      );
      if (mounted) Navigator.of(context).pop(withImages);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: NileColors.bgPage,
        title: const Text('Edit Profile'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: NileColors.volt),
                  )
                : Text('Save',
                    style: NileTextStyles.labelMd()
                        .copyWith(color: NileColors.volt)),
          ),
        ],
      ),
      body: NileMaxWidth(child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Cover + avatar (full-bleed, no horizontal padding) ─────────
              Stack(
                clipBehavior: Clip.none,
                children: [
                  // Cover photo
                  CoverPhoto(
                    url: _remoteCoverUrl,
                    localBytes: _localCoverBytes,
                    height: _coverHeight,
                    onTap: _pickCover,
                  ),

                  // Upload spinner over cover
                  if (_uploadingCover)
                    Positioned.fill(
                      child: Container(
                        color: NileColors.bgPage.withValues(alpha: 0.5),
                        child: const Center(
                          child: CircularProgressIndicator(
                              color: NileColors.volt),
                        ),
                      ),
                    ),

                  // "Edit cover" chip when not uploading and no image yet
                  if (!_uploadingCover &&
                      _localCoverBytes == null &&
                      _remoteCoverUrl == null)
                    Positioned(
                      bottom: 8,
                      right: 12,
                      child: GestureDetector(
                        onTap: _pickCover,
                        child: buildCameraChip('Add cover'),
                      ),
                    ),

                  // Avatar overlapping the cover
                  Positioned(
                    bottom: -_avatarRadius,
                    left: 20,
                    child: GestureDetector(
                      onTap: _pickAvatar,
                      child: Stack(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(3),
                            decoration: const BoxDecoration(
                              color: NileColors.bgPage,
                              shape: BoxShape.circle,
                            ),
                            child: CircleAvatar(
                              radius: _avatarRadius,
                              backgroundColor: NileColors.bgRaised,
                              backgroundImage: _localAvatarBytes != null
                                  ? MemoryImage(_localAvatarBytes!)
                                  : (_remoteAvatarUrl != null
                                      ? NetworkImage(_remoteAvatarUrl!)
                                          as ImageProvider
                                      : null),
                              child: (_localAvatarBytes == null &&
                                      _remoteAvatarUrl == null)
                                  ? Icon(Icons.person,
                                      size: _avatarRadius,
                                      color: NileColors.txtTertiary)
                                  : null,
                            ),
                          ),
                          // Camera badge
                          Positioned(
                            bottom: 3,
                            right: 3,
                            child: Container(
                              decoration: const BoxDecoration(
                                color: NileColors.volt,
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(6),
                              child: _uploadingAvatar
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: NileColors.bgPage),
                                    )
                                  : const Icon(Icons.camera_alt,
                                      size: 14, color: NileColors.bgPage),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              // Clearance for the avatar overhang, then the "Edit photo" link
              // centered horizontally beneath the avatar.
              SizedBox(height: _avatarRadius + 12),
              Padding(
                padding: EdgeInsets.only(left: 20),
                child: SizedBox(
                  width: _avatarRadius * 2,
                  child: Center(
                    child: GestureDetector(
                      onTap: _pickAvatar,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          _uploadingAvatar ? 'Uploading…' : 'Edit photo',
                          style: NileTextStyles.bodySm().copyWith(
                            color: NileColors.volt,
                            decoration: TextDecoration.underline,
                            decorationColor: NileColors.volt,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ── Form fields ───────────────────────────────────────────────
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Column(
                  children: [
                    _NileField(
                      controller: _displayNameCtrl,
                      label: 'Display name',
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    _NileField(
                      controller: _usernameCtrl,
                      label: 'Username',
                      prefix: '@',
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        if (!RegExp(r'^[a-z0-9_]{3,20}$')
                            .hasMatch(v.trim())) {
                          return '3–20 chars: lowercase letters, numbers, underscores';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    _NileField(
                      controller: _bioCtrl,
                      label: 'Bio',
                      maxLines: 3,
                      maxLength: 200,
                      validator: null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      )),
    );
  }
}

// ─── Reusable themed text field ───────────────────────────────────────────────

class _NileField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? prefix;
  final int maxLines;
  final int? maxLength;
  final String? Function(String?)? validator;

  const _NileField({
    required this.controller,
    required this.label,
    this.prefix,
    this.maxLines = 1,
    this.maxLength,
    required this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      maxLength: maxLength,
      validator: validator,
      style: NileTextStyles.bodyLg(),
      decoration: InputDecoration(
        labelText: label,
        prefixText: prefix,
        prefixStyle:
            NileTextStyles.bodyLg().copyWith(color: NileColors.txtTertiary),
        counterStyle: NileTextStyles.caption(),
      ),
    );
  }
}
