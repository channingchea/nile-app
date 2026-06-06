import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_client.dart';

/// Maximum allowed size for any uploaded image (5 MB).
const int kMaxImageBytes = 5 * 1024 * 1024;

/// Thrown when a picked image exceeds [kMaxImageBytes].
class ImageTooLargeException implements Exception {
  @override
  String toString() => 'Image is too large. Please choose one under 5 MB.';
}

// ── Model ─────────────────────────────────────────────────────────────────────

class UserProfile {
  final String id;
  final String username;
  final String displayName;
  final String? bio;
  final String? avatarUrl;
  final String? coverUrl;
  final int followerCount;
  final int followingCount;
  final String? stripeAccountId;
  final DateTime createdAt;

  const UserProfile({
    required this.id,
    required this.username,
    required this.displayName,
    this.bio,
    this.avatarUrl,
    this.coverUrl,
    required this.followerCount,
    required this.followingCount,
    this.stripeAccountId,
    required this.createdAt,
  });

  /// True once the host has begun Stripe Connect onboarding. Live
  /// charges_enabled / payouts_enabled status is fetched from Stripe.
  bool get hasStripeAccount =>
      stripeAccountId != null && stripeAccountId!.isNotEmpty;

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      id: map['id'] as String,
      username: map['username'] as String,
      displayName: map['display_name'] as String,
      bio: map['bio'] as String?,
      avatarUrl: map['avatar_url'] as String?,
      coverUrl: map['cover_url'] as String?,
      followerCount: (map['follower_count'] as num?)?.toInt() ?? 0,
      followingCount: (map['following_count'] as num?)?.toInt() ?? 0,
      stripeAccountId: map['stripe_account_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  UserProfile copyWith({
    String? username,
    String? displayName,
    String? bio,
    String? avatarUrl,
    String? coverUrl,
    int? followerCount,
    int? followingCount,
    String? stripeAccountId,
  }) {
    return UserProfile(
      id: id,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      coverUrl: coverUrl ?? this.coverUrl,
      followerCount: followerCount ?? this.followerCount,
      followingCount: followingCount ?? this.followingCount,
      stripeAccountId: stripeAccountId ?? this.stripeAccountId,
      createdAt: createdAt,
    );
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class ProfileService {
  // ─── Read ─────────────────────────────────────────────────────────────────

  /// Fetch a single profile by user ID.
  ///
  /// Follower/following counts are computed live from the `follows` table
  /// rather than the denormalized `follower_count` / `following_count`
  /// columns on `profiles`, which can drift out of sync.
  static Future<UserProfile?> fetchProfile(String userId) async {
    final profileFuture =
        supabase.from('profiles').select().eq('id', userId).maybeSingle();
    final followersFuture =
        supabase.from('follows').select('follower_id').eq('following_id', userId);
    final followingFuture =
        supabase.from('follows').select('following_id').eq('follower_id', userId);

    final data = await profileFuture;
    if (data == null) return null;

    final followers = await followersFuture;
    final following = await followingFuture;

    data['follower_count'] = (followers as List).length;
    data['following_count'] = (following as List).length;

    return UserProfile.fromMap(data);
  }

  /// Resolve a profile id from its @username (case-insensitive). Used by
  /// inbound share links of the form `/u/<username>`.
  static Future<String?> idForUsername(String username) async {
    final row = await supabase
        .from('profiles')
        .select('id')
        .ilike('username', username)
        .maybeSingle();
    return row?['id'] as String?;
  }

  /// Fetch the currently signed-in user's profile.
  static Future<UserProfile?> fetchCurrentProfile() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return null;
    return fetchProfile(uid);
  }

  // ─── Write ────────────────────────────────────────────────────────────────

  /// Update mutable profile fields. Pass only the fields you want to change.
  static Future<UserProfile> updateProfile({
    required String userId,
    String? displayName,
    String? username,
    String? bio,
  }) async {
    final updates = <String, dynamic>{
      'display_name': ?displayName,
      'username': ?username,
      'bio': ?bio,
    };

    final data = await supabase
        .from('profiles')
        .update(updates)
        .eq('id', userId)
        .select()
        .single();

    return UserProfile.fromMap(data);
  }

  // ─── Avatar upload ────────────────────────────────────────────────────────

  /// Pick an image from the gallery, upload it, and return both the bytes
  /// (for instant local preview) and the new public URL.
  /// Returns null if the user cancels.
  static Future<({Uint8List bytes, String url})?> pickAndUploadAvatar(
      String userId, BuildContext context) async {
    final bytes = await pickImageBytes(
      context,
      cropPathFn: ellipseCropShapeFn,
      allowedAspectRatios: [const CropAspectRatio(width: 1, height: 1)],
    );
    if (bytes == null) return null;
    final url = await uploadAvatarBytes(userId, bytes);
    return (bytes: bytes, url: url);
  }

  /// Upload raw bytes as the user's avatar and return the public URL.
  static Future<String> uploadAvatarBytes(
      String userId, Uint8List bytes) async {
    return _uploadImage(
      storagePath: '$userId/avatar.jpg',
      bytes: bytes,
      profileField: 'avatar_url',
      userId: userId,
    );
  }

  // ─── Cover photo upload ───────────────────────────────────────────────────

  /// Pick an image from the gallery, upload it as the cover photo, and return
  /// both bytes (for instant preview) and the new public URL.
  /// Returns null if the user cancels.
  static Future<({Uint8List bytes, String url})?> pickAndUploadCover(
      String userId, BuildContext context) async {
    final bytes = await pickImageBytes(
      context,
      maxWidth: 600,
      maxHeight: 160,
      allowedAspectRatios: [const CropAspectRatio(width: 15, height: 4)],
    );
    if (bytes == null) return null;
    final url = await uploadCoverBytes(userId, bytes);
    return (bytes: bytes, url: url);
  }

  /// Upload raw bytes as the user's cover photo and return the public URL.
  static Future<String> uploadCoverBytes(
      String userId, Uint8List bytes) async {
    return _uploadImage(
      storagePath: '$userId/cover.jpg',
      bytes: bytes,
      profileField: 'cover_url',
      userId: userId,
    );
  }

  // ─── Shared helpers ───────────────────────────────────────────────────────

  /// Opens the gallery picker, optionally shows a crop UI, and returns the
  /// final bytes, or null if the user cancels the picker.
  ///
  /// Cropping is optional — if the user dismisses the crop screen the original
  /// (resized) bytes are returned.
  static Future<Uint8List?> pickImageBytes(
    BuildContext context, {
    double maxWidth = 512,
    double maxHeight = 512,
    CropShapeFn? cropPathFn,
    List<CropAspectRatio?>? allowedAspectRatios,
  }) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      imageQuality: 85,
    );
    if (picked == null) return null;

    final pickedBytes = await picked.readAsBytes();

    // Attempt crop — returns null if user cancels.
    if (!context.mounted) return null;

    // If exactly one aspect ratio is specified, build initialData with the
    // crop rect pre-set to that ratio so the crop is locked from the start.
    CroppableImageData? initialData;
    if (allowedAspectRatios != null &&
        allowedAspectRatios.length == 1 &&
        allowedAspectRatios.first != null) {
      final ratio = allowedAspectRatios.first!;
      final base = await CroppableImageData.fromImageProvider(
        MemoryImage(pickedBytes),
        cropPathFn: cropPathFn ?? aabbCropShapeFn,
      );
      final imgW = base.imageSize.width;
      final imgH = base.imageSize.height;
      final targetRatio = ratio.width / ratio.height;
      double cropW, cropH;
      if (imgW / imgH > targetRatio) {
        cropH = imgH;
        cropW = imgH * targetRatio;
      } else {
        cropW = imgW;
        cropH = imgW / targetRatio;
      }
      final left = (imgW - cropW) / 2;
      final top = (imgH - cropH) / 2;
      initialData = base.copyWith(
        cropRect: Rect.fromLTWH(left, top, cropW, cropH),
      );
    }

    if (!context.mounted) return null;

    final result = await showNileImageCropper(
      context,
      imageProvider: MemoryImage(pickedBytes),
      initialData: initialData,
      cropPathFn: cropPathFn,
      allowedAspectRatios: allowedAspectRatios,
    );

    final Uint8List bytes;
    if (result != null) {
      final byteData = await result.uiImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      bytes = byteData!.buffer.asUint8List();
    } else {
      bytes = pickedBytes;
    }

    if (bytes.length > kMaxImageBytes) throw ImageTooLargeException();
    return bytes;
  }

  static Future<String> _uploadImage({
    required String storagePath,
    required Uint8List bytes,
    required String profileField,
    required String userId,
  }) async {
    await supabase.storage.from('avatars').uploadBinary(
          storagePath,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );

    final publicUrl = supabase.storage.from('avatars').getPublicUrl(storagePath);
    final bustUrl = '$publicUrl?t=${DateTime.now().millisecondsSinceEpoch}';

    await supabase
        .from('profiles')
        .update({profileField: bustUrl})
        .eq('id', userId);

    return bustUrl;
  }
}

class NileCropperLayoutSnapper extends StatefulWidget {
  final CroppableImageController controller;
  final Widget child;

  const NileCropperLayoutSnapper({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  State<NileCropperLayoutSnapper> createState() => _NileCropperLayoutSnapperState();
}

class _NileCropperLayoutSnapperState extends State<NileCropperLayoutSnapper> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.controller is CroppableImageControllerWithMixins) {
        (widget.controller as CroppableImageControllerWithMixins).setViewportScale();
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<CropImageResult?> showNileImageCropper(
  BuildContext context, {
  required ImageProvider imageProvider,
  CroppableImageData? initialData,
  CroppableImagePostProcessFn? postProcessFn,
  CropShapeFn? cropPathFn,
  List<CropAspectRatio?>? allowedAspectRatios,
  List<Transformation>? enabledTransformations,
  Object? heroTag,
  bool shouldPopAfterCrop = true,
  Locale? locale,
  ThemeData? themeData,
  bool showLoadingIndicatorOnSubmit = false,
  List<CropShapeType> showGestureHandlesOn = const [CropShapeType.aabb],
}) async {
  late final CroppableImageData resolvedInitialData;

  if (initialData != null) {
    resolvedInitialData = initialData;
  } else {
    resolvedInitialData = await CroppableImageData.fromImageProvider(
      imageProvider,
      cropPathFn: cropPathFn ?? aabbCropShapeFn,
    );
  }

  Widget builder(context) {
    return CroppyLocalizationProvider(
      locale: locale,
      child: DefaultMaterialCroppableImageController(
        imageProvider: imageProvider,
        initialData: resolvedInitialData,
        postProcessFn: postProcessFn,
        cropShapeFn: cropPathFn,
        allowedAspectRatios: allowedAspectRatios,
        enabledTransformations: enabledTransformations,
        builder: (context, controller) => NileCropperLayoutSnapper(
          controller: controller,
          child: MaterialImageCropperPage(
            heroTag: heroTag,
            controller: controller,
            shouldPopAfterCrop: shouldPopAfterCrop,
            showLoadingIndicatorOnSubmit: showLoadingIndicatorOnSubmit,
            themeData: themeData,
            showGestureHandlesOn: showGestureHandlesOn,
          ),
        ),
      ),
    );
  }

  if (context.mounted) {
    return Navigator.of(context).push<CropImageResult?>(
      heroTag != null
          ? CupertinoImageCropperWithHeroRoute(builder: builder)
          : MaterialPageRoute(builder: builder),
    );
  }

  return null;
}
