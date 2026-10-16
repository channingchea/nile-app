import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Studio choices that should survive the session: set them once in Studio
/// Preview (or mid-show) and the next real Sound Check opens the same way.
///
/// Per device on purpose — a camera ID or "this mic has its own processing"
/// describes the hardware on this desk, not the account.
class StudioPrefs {
  StudioPrefs._(this._p);

  final SharedPreferences _p;

  static const _kCamera = 'studio.cameraDeviceId';
  static const _kExternalMic = 'studio.externalMicProcessing';
  static const _kChatVisible = 'studio.chatVisible';
  static const _kVideoStartsOff = 'studio.videoStartsOff';

  static Future<StudioPrefs> load() async =>
      StudioPrefs._(await SharedPreferences.getInstance());

  /// The picked camera, or null for the system default. A saved ID that is no
  /// longer attached is the caller's to ignore — it stays saved so plugging the
  /// camera back in brings the choice back with it.
  String? get cameraDeviceId => _p.getString(_kCamera);
  set cameraDeviceId(String? id) => unawaited(
    id == null ? _p.remove(_kCamera) : _p.setString(_kCamera, id),
  );

  bool get externalMicProcessing => _p.getBool(_kExternalMic) ?? false;
  set externalMicProcessing(bool v) => unawaited(_p.setBool(_kExternalMic, v));

  bool get chatVisible => _p.getBool(_kChatVisible) ?? true;
  set chatVisible(bool v) => unawaited(_p.setBool(_kChatVisible, v));

  bool get videoStartsOff => _p.getBool(_kVideoStartsOff) ?? false;
  set videoStartsOff(bool v) => unawaited(_p.setBool(_kVideoStartsOff, v));
}
