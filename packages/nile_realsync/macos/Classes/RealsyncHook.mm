// RealSync (Studio master host, phase 7a) — iOS/macOS.
//
// What it does: sets the WebRTC jitter-buffer minimum delay on ONE remote
// receiver, so a camera that runs ahead of the show audio can be held back
// (or the audio held back for a camera that runs behind).
//
// Why it looks like this: libwebrtc has the call —
// webrtc::RtpReceiverInterface::SetJitterBufferMinimumDelay(optional<double>) —
// but the WebRTC-SDK framework ships no C++ headers and its ObjC
// RTCRtpReceiver doesn't expose it. The native receiver lives in the private
// ivar `_nativeRtpReceiver` (a scoped_refptr, i.e. one pointer). We call the
// method through its vtable slot.
//
// Why that is safe enough to ship: the slot is not assumed — selfTest() proves
// it against the loaded binary at launch. The framework exports the base
// class's vtable and several of its default methods, so we check that the
// slots around ours hold exactly the functions api/rtp_receiver_interface.h
// says they should (pure virtuals where the header has `= 0`, the exported
// defaults where it has bodies). Any WebRTC upgrade that moves a slot fails
// the test and RealSync switches itself off; nothing is ever called blind.

#import "RealsyncHook.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <optional>

namespace {

// RtpReceiverInterface vtable, M144 (api/rtp_receiver_interface.h):
//  0 AddRef=0  1 Release=0  2,3 ~dtor  4 track=0  5 dtls_transport
//  6 stream_ids  7 streams  8 media_type=0  9 id=0  10 GetParameters=0
//  11 SetParameters  12 SetObserver=0  13 SetJitterBufferMinimumDelay=0
//  14 GetSources  15 SetFrameDecryptor  16 GetFrameDecryptor
constexpr int kSetJitterBufferMinimumDelay = 13;

using SetDelayFn = void (*)(void *self, std::optional<double> seconds);

void *Sym(const char *name) { return dlsym(RTLD_DEFAULT, name); }

/// Why the hook can't be used, or nil when it can.
NSString *SelfTestFailure() {
  auto *vtable = static_cast<void *const *>(Sym("_ZTVN6webrtc20RtpReceiverInterfaceE"));
  void *getSources = Sym("_ZNK6webrtc20RtpReceiverInterface10GetSourcesEv");
  void *dtls = Sym("_ZNK6webrtc20RtpReceiverInterface14dtls_transportEv");
  void *getDecryptor = Sym("_ZNK6webrtc20RtpReceiverInterface17GetFrameDecryptorEv");
  void *setDecryptor = Sym(
      "_ZN6webrtc20RtpReceiverInterface17SetFrameDecryptorENS_13scoped_refptrINS_"
      "23FrameDecryptorInterfaceEEE");
  if (!vtable || !getSources || !dtls || !getDecryptor || !setDecryptor) {
    return @"WebRTC symbols not found";
  }
  void *const *slot = vtable + 2;  // skip offset-to-top and typeinfo
  void *pure = slot[0];            // AddRef is pure virtual
  if (slot[1] != pure || slot[4] != pure || slot[8] != pure || slot[9] != pure ||
      slot[10] != pure || slot[12] != pure || slot[kSetJitterBufferMinimumDelay] != pure) {
    return @"pure-virtual slots moved";
  }
  if (slot[11] == pure) return @"SetParameters slot moved";
  if (slot[5] != dtls) return @"dtls_transport slot moved";
  if (slot[14] != getSources) return @"GetSources slot moved";
  if (slot[15] != setDecryptor) return @"SetFrameDecryptor slot moved";
  if (slot[16] != getDecryptor) return @"GetFrameDecryptor slot moved";

  Class receiverClass = NSClassFromString(@"RTCRtpReceiver");
  Ivar ivar = receiverClass ? class_getInstanceVariable(receiverClass, "_nativeRtpReceiver") : nil;
  if (!ivar) return @"RTCRtpReceiver has no native receiver";
  const char *type = ivar_getTypeEncoding(ivar);
  if (!type || !strstr(type, "RtpReceiverInterface")) return @"native receiver type changed";

  if (!NSClassFromString(@"FlutterWebRTCPlugin")) return @"flutter_webrtc not loaded";
  return nil;
}

NSString *CachedFailure() {
  static NSString *failure;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    failure = SelfTestFailure() ?: @"";
  });
  return failure.length ? failure : nil;
}

/// flutter_webrtc's receiver with this id, across every peer connection.
id FindReceiver(NSString *receiverId) {
  Class pluginClass = NSClassFromString(@"FlutterWebRTCPlugin");
  SEL shared = NSSelectorFromString(@"sharedSingleton");
  if (!pluginClass || ![pluginClass respondsToSelector:shared]) return nil;
  id plugin = ((id (*)(id, SEL))objc_msgSend)(pluginClass, shared);
  NSDictionary *pcs = nil;
  @try {
    pcs = [plugin valueForKey:@"peerConnections"];
  } @catch (NSException *) {
    return nil;
  }
  for (id pc in pcs.allValues) {
    for (id receiver in [pc valueForKey:@"receivers"]) {
      if ([[receiver valueForKey:@"receiverId"] isEqualToString:receiverId]) return receiver;
    }
  }
  return nil;
}

BOOL SetMinimumDelayOn(id receiver, std::optional<double> seconds) {
  Ivar ivar = class_getInstanceVariable([receiver class], "_nativeRtpReceiver");
  if (!ivar) return NO;
  void *native = *reinterpret_cast<void **>(
      reinterpret_cast<uint8_t *>((__bridge void *)receiver) + ivar_getOffset(ivar));
  if (!native) return NO;
  auto **vtable = *reinterpret_cast<void ***>(native);
  // The receiver is a proxy: this hops to the worker thread inside libwebrtc.
  reinterpret_cast<SetDelayFn>(vtable[kSetJitterBufferMinimumDelay])(native, seconds);
  return YES;
}

}  // namespace

NSString *NileRealsyncUnavailableReason(void) { return CachedFailure(); }

BOOL NileRealsyncSetMinimumDelay(NSString *receiverId, double seconds) {
  if (CachedFailure()) return NO;
  id receiver = FindReceiver(receiverId);
  if (!receiver) return NO;
  std::optional<double> delay;
  if (seconds >= 0) delay = MIN(seconds, 10.0);  // libwebrtc's own ceiling is 10 s
  return SetMinimumDelayOn(receiver, delay);
}
