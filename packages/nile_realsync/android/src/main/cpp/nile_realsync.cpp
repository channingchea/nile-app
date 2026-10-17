// RealSync (Studio master host, phase 7a) — Android.
//
// Calls webrtc::RtpReceiverInterface::SetJitterBufferMinimumDelay on the native
// receiver behind an org.webrtc.RtpReceiver (its `nativeRtpReceiver` field),
// through the vtable slot from api/rtp_receiver_interface.h (M144 — see the
// darwin plugin for the full slot map; the layout is the same Itanium ABI).
//
// Android's libwebrtc exports no C++ symbols, so the slot can't be proven
// against the binary the way iOS/macOS do. What is checked instead, before
// every call: the vtable and both neighbouring slots resolve into the loaded
// libjingle_peerconnection_so image, and slot 13 differs from slot 12 (two
// distinct overrides, as in every receiver proxy). flutter_webrtc pins
// WebRTC-SDK 144.7559.01; the app pins flutter_webrtc, so the layout can only
// change with a deliberate upgrade — re-run the RealSync rig before one.

#include <dlfcn.h>
#include <jni.h>

#include <cstring>
#include <optional>
#include <string>

#include "realsync_stamp.h"

namespace {

constexpr int kSetJitterBufferMinimumDelay = 13;
using SetDelayFn = void (*)(void* self, std::optional<double> seconds);

bool InWebRtcImage(const void* p) {
  Dl_info info{};
  return p && dladdr(p, &info) && info.dli_fname &&
         std::strstr(info.dli_fname, "jingle_peerconnection") != nullptr;
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_joinnile_realsync_NileRealsyncPlugin_nativeCheck(JNIEnv* env, jclass, jlong ptr) {
  auto* native = reinterpret_cast<void*>(ptr);
  if (!native) return env->NewStringUTF("no native receiver");
  auto** vtable = *reinterpret_cast<void***>(native);
  if (!InWebRtcImage(vtable)) return env->NewStringUTF("receiver vtable outside libwebrtc");
  void* setObserver = vtable[kSetJitterBufferMinimumDelay - 1];
  void* setDelay = vtable[kSetJitterBufferMinimumDelay];
  void* getSources = vtable[kSetJitterBufferMinimumDelay + 1];
  if (!InWebRtcImage(setObserver) || !InWebRtcImage(setDelay) || !InWebRtcImage(getSources)) {
    return env->NewStringUTF("receiver slots outside libwebrtc");
  }
  if (setDelay == setObserver || setDelay == getSources) {
    return env->NewStringUTF("receiver slots not distinct");
  }
  return nullptr;
}

extern "C" JNIEXPORT void JNICALL
Java_com_joinnile_realsync_NileRealsyncPlugin_nativeSetDelay(JNIEnv*, jclass, jlong ptr,
                                                             jdouble seconds, jboolean clear) {
  auto* native = reinterpret_cast<void*>(ptr);
  if (!native) return;
  auto** vtable = *reinterpret_cast<void***>(native);
  reinterpret_cast<SetDelayFn>(vtable[kSetJitterBufferMinimumDelay])(
      native, clear ? std::nullopt : std::optional<double>(seconds));
}

// ── Capture stamps (shared C++ in src/realsync_stamp.cc) ────────────────────

bool nile_rs::InWebRtcImage(const void* p) { return ::InWebRtcImage(p); }

namespace {

std::string Str(JNIEnv* env, jstring s) {
  const char* c = env->GetStringUTFChars(s, nullptr);
  std::string out(c ? c : "");
  if (c) env->ReleaseStringUTFChars(s, c);
  return out;
}

}  // namespace

/// Same standard as the delay hook: the SetFrameTransformer slot and its
/// neighbours resolve into libwebrtc and are distinct functions.
extern "C" JNIEXPORT jstring JNICALL
Java_com_joinnile_realsync_NileRealsyncPlugin_nativeStampCheck(JNIEnv* env, jclass, jlong ptr,
                                                               jboolean sender) {
  auto* native = reinterpret_cast<void*>(ptr);
  if (!native) return env->NewStringUTF("no native object");
  auto** vtable = *reinterpret_cast<void***>(native);
  if (!InWebRtcImage(vtable)) return env->NewStringUTF("vtable outside libwebrtc");
  const int slot = sender ? nile_rs::kSenderSetFrameTransformer : nile_rs::kReceiverSetFrameTransformer;
  void* before = vtable[slot - 1];
  void* target = vtable[slot];
  void* earlier = vtable[slot - 2];
  if (!InWebRtcImage(before) || !InWebRtcImage(target) || !InWebRtcImage(earlier)) {
    return env->NewStringUTF("transformer slots outside libwebrtc");
  }
  if (target == before || target == earlier) return env->NewStringUTF("transformer slots not distinct");
  return nullptr;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_joinnile_realsync_NileRealsyncPlugin_nativeStampSender(JNIEnv* env, jclass, jstring id,
                                                                jlong ptr, jboolean audio,
                                                                jint opus_pt, jint red_pt) {
  return nile_rs::StampSender(Str(env, id), reinterpret_cast<void*>(ptr),
                              audio ? nile_rs::Media::kAudio : nile_rs::Media::kVideo, opus_pt, red_pt);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_joinnile_realsync_NileRealsyncPlugin_nativeReadReceiver(JNIEnv* env, jclass, jstring id,
                                                                 jlong ptr, jboolean audio) {
  return nile_rs::ReadReceiver(Str(env, id), reinterpret_cast<void*>(ptr),
                               audio ? nile_rs::Media::kAudio : nile_rs::Media::kVideo);
}

extern "C" JNIEXPORT void JNICALL
Java_com_joinnile_realsync_NileRealsyncPlugin_nativeForget(JNIEnv* env, jclass, jstring id) {
  nile_rs::Forget(Str(env, id));
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_joinnile_realsync_NileRealsyncPlugin_nativeAge(JNIEnv* env, jclass, jstring id, jint window_ms) {
  double median = 0;
  int count = 0;
  if (!nile_rs::ReceiverAge(Str(env, id), window_ms, &median, &count)) return nullptr;
  jdoubleArray out = env->NewDoubleArray(2);
  const jdouble values[2] = {median, static_cast<jdouble>(count)};
  env->SetDoubleArrayRegion(out, 0, 2, values);
  return out;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_joinnile_realsync_NileRealsyncPlugin_nativeStampedCount(JNIEnv* env, jclass, jstring id) {
  return nile_rs::StampedCount(Str(env, id));
}
