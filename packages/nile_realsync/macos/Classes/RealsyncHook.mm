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

#include "realsync_stamp.h"

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

// ── Capture stamps (route a: in-band capture time) ──────────────────────────
//
// The stamping itself is shared C++ (src/realsync_stamp.cc). Here: prove the
// SetFrameTransformer slots against the loaded binary, find flutter_webrtc's
// native senders/receivers, and read each sender's negotiated audio codecs.

bool nile_rs::InWebRtcImage(const void *p) {
  Dl_info info{};
  return p && dladdr(p, &info) && info.dli_fname && strstr(info.dli_fname, "/WebRTC");
}

namespace {

/// RtpSenderInterface (M144, api/rtp_sender_interface.h):
///  0 AddRef=0 1 Release=0 2,3 ~dtor 4 SetTrack=0 5 track=0 6 dtls_transport=0
///  7 ssrc=0 8 media_type=0 9 id=0 10 stream_ids=0 11 SetStreams=0
///  12 init_send_encodings=0 13 GetParameters=0 14 SetParameters=0
///  15 SetParametersAsync 16 SetObserver 17 GetDtmfSender=0 18 SetFrameEncryptor=0
///  19 GetFrameEncryptor=0 20 SetEncoderToPacketizerFrameTransformer
///  21 SetEncoderSelector=0 22 SetFrameTransformer (FrameTransformerHost override)
/// RtpReceiverInterface: 17 SetDepacketizerToDecoderFrameTransformer
///  18 SetFrameTransformer (exported default).
NSString *StampSlotFailure() {
  auto *sv = static_cast<void *const *>(Sym("_ZTVN6webrtc18RtpSenderInterfaceE"));
  auto *rv = static_cast<void *const *>(Sym("_ZTVN6webrtc20RtpReceiverInterfaceE"));
  void *setParamsAsync = Sym(
      "_ZN6webrtc18RtpSenderInterface18SetParametersAsyncERKNS_13RtpParametersEN4absl12"
      "AnyInvocableIFvNS_8RTCErrorEOEEE");
  void *recvSetTransformer = Sym(
      "_ZN6webrtc20RtpReceiverInterface19SetFrameTransformerENS_13scoped_refptrINS_"
      "25FrameTransformerInterfaceEEE");
  if (!sv || !rv || !setParamsAsync || !recvSetTransformer) return @"transformer symbols not found";
  void *const *s = sv + 2, *const *r = rv + 2;
  void *pure = s[0];
  for (int i : {1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 17, 18, 19, 21}) {
    if (s[i] != pure) return @"sender pure-virtual slots moved";
  }
  if (s[15] != setParamsAsync) return @"sender SetParametersAsync slot moved";
  if (s[16] == pure || s[20] == pure || s[nile_rs::kSenderSetFrameTransformer] == pure) {
    return @"sender SetFrameTransformer slot moved";
  }
  if (r[17] == pure || r[nile_rs::kReceiverSetFrameTransformer] != recvSetTransformer) {
    return @"receiver SetFrameTransformer slot moved";
  }
  Class senderClass = NSClassFromString(@"RTCRtpSender");
  Ivar ivar = senderClass ? class_getInstanceVariable(senderClass, "_nativeRtpSender") : nil;
  const char *type = ivar ? ivar_getTypeEncoding(ivar) : nullptr;
  if (!type || !strstr(type, "RtpSenderInterface")) return @"native sender type changed";
  return nil;
}

/// The jitter hook's checks (flutter_webrtc loaded, receiver ivar) plus the
/// transformer slots.
NSString *StampSelfTestFailure() { return CachedFailure() ?: StampSlotFailure(); }

NSString *CachedStampFailure() {
  static NSString *failure;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    failure = StampSelfTestFailure() ?: @"";
  });
  return failure.length ? failure : nil;
}

NSArray *AllPeerConnections() {
  Class pluginClass = NSClassFromString(@"FlutterWebRTCPlugin");
  SEL shared = NSSelectorFromString(@"sharedSingleton");
  if (!pluginClass || ![pluginClass respondsToSelector:shared]) return @[];
  id plugin = ((id (*)(id, SEL))objc_msgSend)(pluginClass, shared);
  @try {
    return [[plugin valueForKey:@"peerConnections"] allValues] ?: @[];
  } @catch (NSException *) {
    return @[];
  }
}

id FindSender(NSString *senderId) {
  for (id pc in AllPeerConnections()) {
    for (id sender in [pc valueForKey:@"senders"]) {
      if ([[sender valueForKey:@"senderId"] isEqualToString:senderId]) return sender;
    }
  }
  return nil;
}

void *Native(id obj, const char *ivarName) {
  Ivar ivar = obj ? class_getInstanceVariable([obj class], ivarName) : nil;
  if (!ivar) return nullptr;
  return *reinterpret_cast<void **>(reinterpret_cast<uint8_t *>((__bridge void *)obj) +
                                    ivar_getOffset(ivar));
}

/// The sender's negotiated payload type for a codec name, or -1.
int PayloadType(id sender, NSString *name) {
  @try {
    for (id codec in [[sender valueForKey:@"parameters"] valueForKey:@"codecs"]) {
      if ([[codec valueForKey:@"name"] caseInsensitiveCompare:name] == NSOrderedSame) {
        return [[codec valueForKey:@"payloadType"] intValue];
      }
    }
  } @catch (NSException *) {
  }
  return -1;
}

}  // namespace

NSString *NileRealsyncStampUnavailableReason(void) { return CachedStampFailure(); }

BOOL NileRealsyncStampSender(NSString *senderId, BOOL audio) {
  if (CachedStampFailure()) return NO;
  id sender = FindSender(senderId);
  void *native = Native(sender, "_nativeRtpSender");
  if (!native) return NO;
  return nile_rs::StampSender(senderId.UTF8String, native,
                              audio ? nile_rs::Media::kAudio : nile_rs::Media::kVideo,
                              audio ? PayloadType(sender, @"opus") : -1,
                              audio ? PayloadType(sender, @"red") : -1);
}

BOOL NileRealsyncReadReceiver(NSString *receiverId, BOOL audio) {
  if (CachedStampFailure()) return NO;
  void *native = Native(FindReceiver(receiverId), "_nativeRtpReceiver");
  if (!native) return NO;
  return nile_rs::ReadReceiver(receiverId.UTF8String, native,
                               audio ? nile_rs::Media::kAudio : nile_rs::Media::kVideo);
}

void NileRealsyncForget(NSString *nativeId) { nile_rs::Forget(nativeId.UTF8String); }

NSDictionary *NileRealsyncAges(NSArray *receiverIds, int windowMs) {
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (id rid in receiverIds) {
    if (![rid isKindOfClass:NSString.class]) continue;
    double median = 0;
    int count = 0;
    if (nile_rs::ReceiverAge([rid UTF8String], windowMs, &median, &count)) {
      out[rid] = @{@"ageMs" : @(median), @"count" : @(count)};
    }
  }
  return out;
}

long long NileRealsyncStampedCount(NSString *senderId) {
  return nile_rs::StampedCount(senderId.UTF8String);
}
