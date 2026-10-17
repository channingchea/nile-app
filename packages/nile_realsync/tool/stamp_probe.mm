// RealSync capture-stamp probe — run from nile_app/:
//   packages/nile_realsync/tool/run_stamp_probe.sh
//
// Proves the shared frame transformer against the WebRTC build in macos/Pods,
// outside the app: two in-process peer connections, synthetic video plus the
// default audio source, every sent frame stamped, every received frame read.
//   NILE_PROBE_NOREAD=1  stamp but don't read — decoders must cope unaided
//   NILE_PROBE_CODEC=VP8|H264  prefer that video codec
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <WebRTC/WebRTC.h>
#include "../macos/Classes/RealsyncHook.mm"

static void Spin(double seconds, BOOL (^until)(void)) {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ((!until || !until()) && [end timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  }
}

static NSDictionary *Inbound(RTCPeerConnection *pc, RTCRtpReceiver *r) {
  __block NSDictionary *out = nil;
  __block BOOL done = NO;
  [pc statisticsForReceiver:r completionHandler:^(RTCStatisticsReport *report) {
    for (RTCStatistics *s in report.statistics.allValues) {
      if ([s.type isEqualToString:@"inbound-rtp"]) out = s.values;
    }
    done = YES;
  }];
  Spin(3, ^{ return done; });
  return out;
}

static void Age(const char *label, NSString *rid) {
  double ms = 0;
  int n = 0;
  if (nile_rs::ReceiverAge(rid.UTF8String, 1500, &ms, &n)) {
    NSLog(@"%s: %d stamped frames in 1.5 s, median arrival age %.1f ms", label, n, ms);
  } else {
    NSLog(@"%s: NO stamped frames read", label);
  }
}

int main() {
  @autoreleasepool {
    NSString *slots = StampSlotFailure();
    NSLog(@"transformer slots: %@", slots ?: @"PASS");
    if (slots) return 1;
    BOOL read = getenv("NILE_PROBE_NOREAD") == NULL;
    NSString *codec = getenv("NILE_PROBE_CODEC") ? @(getenv("NILE_PROBE_CODEC")) : nil;

    RTCPeerConnectionFactory *f = [[RTCPeerConnectionFactory alloc] init];
    // Loopback only: a new binary talking over the LAN address trips macOS's
    // Local Network permission; 127.0.0.1 doesn't.
    RTCPeerConnectionFactoryOptions *opts = [RTCPeerConnectionFactoryOptions new];
    opts.ignoreLoopbackNetworkAdapter = NO;
    opts.ignoreEthernetNetworkAdapter = YES;
    opts.ignoreWiFiNetworkAdapter = YES;
    opts.ignoreVPNNetworkAdapter = YES;
    opts.ignoreCellularNetworkAdapter = YES;
    [f setOptions:opts];
    RTCConfiguration *cfg = [RTCConfiguration new];
    cfg.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    RTCMediaConstraints *c = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil
                                                                  optionalConstraints:nil];
    RTCPeerConnection *a = [f peerConnectionWithConfiguration:cfg constraints:c delegate:nil];
    RTCPeerConnection *b = [f peerConnectionWithConfiguration:cfg constraints:c delegate:nil];
    RTCVideoSource *source = [f videoSource];
    RTCVideoCapturer *capturer = [[RTCVideoCapturer alloc] initWithDelegate:source];
    RTCRtpSender *vs = [a addTrack:[f videoTrackWithSource:source trackId:@"v0"] streamIds:@[ @"s" ]];
    // NILE_PROBE_NOAUDIO: video only (the default audio source opens the mic).
    RTCRtpSender *as = getenv("NILE_PROBE_NOAUDIO") ? nil
        : [a addTrack:[f audioTrackWithSource:[f audioSourceWithConstraints:c] trackId:@"a0"] streamIds:@[ @"s" ]];
    if (codec) {
      for (RTCRtpTransceiver *t in a.transceivers) {
        if (t.mediaType != RTCRtpMediaTypeVideo) continue;
        NSMutableArray *prefs = [NSMutableArray array];
        for (RTCRtpCodecCapability *cap in [f rtpSenderCapabilitiesForKind:@"video"].codecs) {
          if ([cap.name isEqualToString:codec]) [prefs insertObject:cap atIndex:0];
          else [prefs addObject:cap];
        }
        NSError *err = nil;
        [t setCodecPreferences:prefs error:&err];
        if (err) NSLog(@"codec preference failed: %@", err);
      }
    }

    __block BOOL step = NO;
    __weak RTCPeerConnection *wa = a, *wb = b;
    [a offerForConstraints:c completionHandler:^(RTCSessionDescription *o, NSError *e) {
      [wa setLocalDescription:o completionHandler:^(NSError *e2) { step = YES; }];
    }];
    Spin(5, ^{ return (BOOL)(step && a.iceGatheringState == RTCIceGatheringStateComplete); });
    step = NO;
    [b setRemoteDescription:a.localDescription completionHandler:^(NSError *e) {
      if (e) NSLog(@"b remote: %@", e);
      [wb answerForConstraints:c completionHandler:^(RTCSessionDescription *ans, NSError *e2) {
        [wb setLocalDescription:ans completionHandler:^(NSError *e3) { if (e3 || e2) NSLog(@"b local: %@ %@", e2, e3); step = YES; }];
      }];
    }];
    Spin(5, ^{ return (BOOL)(step && b.iceGatheringState == RTCIceGatheringStateComplete); });
    step = NO;
    [a setRemoteDescription:b.localDescription completionHandler:^(NSError *e) { if (e) NSLog(@"a remote: %@", e); step = YES; }];
    Spin(5, ^{ return step; });

    NSLog(@"gathering a=%ld b=%ld; candidates a=%lu b=%lu", (long)a.iceGatheringState, (long)b.iceGatheringState,
          (unsigned long)([a.localDescription.sdp componentsSeparatedByString:@"a=candidate"].count - 1),
          (unsigned long)([b.localDescription.sdp componentsSeparatedByString:@"a=candidate"].count - 1));
    if (getenv("NILE_PROBE_SDP")) NSLog(@"A:\n%@\nB:\n%@", a.localDescription.sdp, b.localDescription.sdp);
    NSLog(@"after negotiation: a ice %ld, b ice %ld, b transceivers %lu, answer has audio: %@", (long)a.iceConnectionState, (long)b.iceConnectionState, (unsigned long)b.transceivers.count, [b.localDescription.sdp containsString:@"m=audio"] ? @"yes" : @"no");
    int opus = PayloadType(as, @"opus"), red = PayloadType(as, @"red");
    NSLog(@"audio codecs: opus pt %d, red pt %d", opus, red);
    BOOL stamp = getenv("NILE_PROBE_NOSTAMP") == NULL;
    BOOL okV = stamp && nile_rs::StampSender("vs", Native(vs, "_nativeRtpSender"), nile_rs::Media::kVideo, -1, -1);
    BOOL okA = stamp && as && nile_rs::StampSender("as", Native(as, "_nativeRtpSender"), nile_rs::Media::kAudio, opus, red);
    RTCRtpReceiver *vr = nil, *ar = nil;
    for (RTCRtpTransceiver *t in b.transceivers) {
      if (t.mediaType == RTCRtpMediaTypeVideo) vr = t.receiver;
      else ar = t.receiver;
    }
    if (read && stamp) {
      nile_rs::ReadReceiver(vr.receiverId.UTF8String, Native(vr, "_nativeRtpReceiver"), nile_rs::Media::kVideo);
      if (ar) nile_rs::ReadReceiver(ar.receiverId.UTF8String, Native(ar, "_nativeRtpReceiver"), nile_rs::Media::kAudio);
    }
    NSLog(@"installed: video %@, audio %@; reading: %@; video codec: %@", okV ? @"yes" : @"NO",
          okA ? @"yes" : @"NO", read ? @"yes" : @"no (decoders unaided)", codec ?: @"default");

    CVPixelBufferRef px = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        (__bridge CFDictionaryRef) @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}}, &px);
    RTCCVPixelBuffer *buffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:px];
    __block int tick = 0;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) {
      // Change the picture every frame so the encoder emits real data.
      CVPixelBufferLockBaseAddress(px, 0);
      memset(CVPixelBufferGetBaseAddressOfPlane(px, 0), (tick++ * 7) & 0xFF,
             CVPixelBufferGetBytesPerRowOfPlane(px, 0) * 40);
      CVPixelBufferUnlockBaseAddress(px, 0);
      [source capturer:capturer
          didCaptureVideoFrame:[[RTCVideoFrame alloc] initWithBuffer:buffer
                                                            rotation:RTCVideoRotation_0
                                                         timeStampNs:(int64_t)(CACurrentMediaTime() * 1e9)]];
    }];
    Spin(6, nil);
    NSDictionary *v0 = Inbound(b, vr), *a0 = Inbound(b, ar);
    Spin(4, nil);
    NSDictionary *v1 = Inbound(b, vr), *a1 = Inbound(b, ar);
    long long sv = nile_rs::StampedCount("vs"), sa = nile_rs::StampedCount("as");
    NSLog(@"connected: %@; stamped video %lld, audio %lld",
          b.connectionState == RTCPeerConnectionStateConnected ? @"yes" : @"NO", sv, sa);
    int recv = [v1[@"framesReceived"] intValue] - [v0[@"framesReceived"] intValue];
    int dec = [v1[@"framesDecoded"] intValue] - [v0[@"framesDecoded"] intValue];
    NSLog(@"video over 4 s: %d received, %d decoded, %@ dropped total, pli %@, decoder %@ (codec %@), %@x%@", recv, dec,
          v1[@"framesDropped"], v1[@"pliCount"], v1[@"decoderImplementation"], v1[@"codecId"],
    NSLog(@"audio over 4 s: %d packets, %d samples, %d concealed",
          [a1[@"packetsReceived"] intValue] - [a0[@"packetsReceived"] intValue],
          [a1[@"totalSamplesReceived"] intValue] - [a0[@"totalSamplesReceived"] intValue],
          [a1[@"concealedSamples"] intValue] - [a0[@"concealedSamples"] intValue]);
    if (read) {
      Age("video", vr.receiverId);
      if (ar) Age("audio", ar.receiverId);
    }

    // Forget: frames keep flowing, unstamped.
    nile_rs::Forget("vs");
    nile_rs::Forget(vr.receiverId.UTF8String);
    Spin(3, nil);
    NSDictionary *v2 = Inbound(b, vr);
    Spin(2, nil);
    NSDictionary *v3 = Inbound(b, vr);
    int after = [v3[@"framesDecoded"] intValue] - [v2[@"framesDecoded"] intValue];
    NSLog(@"after detaching video: %d frames decoded in 2 s", after);

    [timer invalidate];
    [a close];
    [b close];
    CVPixelBufferRelease(px);
    BOOL ok = okV && sv > 60 && dec >= recv - 2 && dec > 60 && after > 30;
    NSLog(@"%@", ok ? @"STAMP PROBE PASS" : @"STAMP PROBE FAIL");
    return ok ? 0 : 1;
  }
}
