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
