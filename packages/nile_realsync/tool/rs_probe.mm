// RealSync 7a probe — run from nile_app/: packages/nile_realsync/tool/run_probe.sh
//
// 1. Runs the plugin's launch self-test against the WebRTC build in macos/Pods
//    (outside the app the last check, "flutter_webrtc not loaded", is expected).
// 2. Opens two peer connections to each other in-process, sends synthetic
//    video (no camera or mic involved), and on the receiving side:
//      - confirms inbound-rtp reports estimatedPlayoutTimestamp,
//      - sets a 600 ms minimum playout delay through the hook and checks the
//        jitter buffer's target delay actually rises to meet it,
//      - clears it again.
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

/// NILE_PROBE_RRTR: advertise RTCP XR receiver reference time on every codec,
/// so a receive-only stream can learn its round-trip time.
static RTCSessionDescription *Rrtr(RTCSessionDescription *d) {
  if (!getenv("NILE_PROBE_RRTR")) return d;
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"a=rtcp-fb:(\\d+) nack\r\n"
                                                                      options:0 error:nil];
  NSString *sdp = [re stringByReplacingMatchesInString:d.sdp options:0 range:NSMakeRange(0, d.sdp.length)
                                          withTemplate:@"a=rtcp-fb:$1 nack\r\na=rtcp-fb:$1 rrtr\r\n"];
  return [[RTCSessionDescription alloc] initWithType:d.type sdp:sdp];
}

static NSDictionary *InboundVideo(RTCPeerConnection *pc, RTCRtpReceiver *r) {
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

/// Average jitter-buffer target delay (ms) over frames emitted between two reports.
static double TargetMs(NSDictionary *before, NSDictionary *after) {
  double d = [after[@"jitterBufferTargetDelay"] doubleValue] - [before[@"jitterBufferTargetDelay"] doubleValue];
  double n = [after[@"jitterBufferEmittedCount"] doubleValue] - [before[@"jitterBufferEmittedCount"] doubleValue];
  return n > 0 ? d / n * 1000 : -1;
}

int main() {
  @autoreleasepool {
    NSLog(@"self-test: %@", SelfTestFailure() ?: @"PASS");

    RTCPeerConnectionFactory *f = [[RTCPeerConnectionFactory alloc] init];
    RTCConfiguration *cfg = [RTCConfiguration new];
    cfg.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    RTCMediaConstraints *c = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil
                                                                  optionalConstraints:nil];
    RTCPeerConnection *a = [f peerConnectionWithConfiguration:cfg constraints:c delegate:nil];
    RTCPeerConnection *b = [f peerConnectionWithConfiguration:cfg constraints:c delegate:nil];
    RTCVideoSource *source = [f videoSource];
    RTCVideoCapturer *capturer = [[RTCVideoCapturer alloc] initWithDelegate:source];
    [a addTrack:[f videoTrackWithSource:source trackId:@"v0"] streamIds:@[ @"s" ]];
    // Two-way when NILE_PROBE_TWOWAY is set: B sends video back, so both sides
    // can measure round-trip time. Tells whether RTT gates the playout stat.
    BOOL twoWay = getenv("NILE_PROBE_TWOWAY") != NULL;
    if (twoWay) [b addTrack:[f videoTrackWithSource:source trackId:@"v1"] streamIds:@[ @"t" ]];
    NSLog(@"rrtr: %@", getenv("NILE_PROBE_RRTR") ? @"on" : @"off");
    NSLog(@"mode: %@", twoWay ? @"two-way" : @"receive-only (like a LiveKit viewer)");

    // Non-trickle negotiation: wait for ICE gathering, then hand over SDPs.
    __block BOOL step = NO;
    __weak RTCPeerConnection *wa = a, *wb = b;
    [a offerForConstraints:c completionHandler:^(RTCSessionDescription *o, NSError *e) {
      [wa setLocalDescription:o completionHandler:^(NSError *e2) { step = YES; }];
    }];
    Spin(5, ^{ return (BOOL)(step && a.iceGatheringState == RTCIceGatheringStateComplete); });
    step = NO;
    [b setRemoteDescription:Rrtr(a.localDescription) completionHandler:^(NSError *e) {
      [wb answerForConstraints:c completionHandler:^(RTCSessionDescription *ans, NSError *e2) {
        [wb setLocalDescription:ans completionHandler:^(NSError *e3) { step = YES; }];
      }];
    }];
    Spin(5, ^{ return (BOOL)(step && b.iceGatheringState == RTCIceGatheringStateComplete); });
    step = NO;
    [a setRemoteDescription:Rrtr(b.localDescription) completionHandler:^(NSError *e) { step = YES; }];
    Spin(5, ^{ return step; });

    NSLog(@"gathering a=%ld b=%ld; candidates a=%lu b=%lu",
          (long)a.iceGatheringState, (long)b.iceGatheringState,
          (unsigned long)([a.localDescription.sdp componentsSeparatedByString:@"a=candidate"].count - 1),
          (unsigned long)([b.localDescription.sdp componentsSeparatedByString:@"a=candidate"].count - 1));
    NSString *cand = nil;
    for (NSString *l in [a.localDescription.sdp componentsSeparatedByString:@"\r\n"]) {
      if ([l hasPrefix:@"a=candidate"]) { cand = l; break; }
    }
    NSLog(@"first candidate: %@", cand);
    // 30 fps of synthetic frames for the rest of the probe.
    CVPixelBufferRef px = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        (__bridge CFDictionaryRef) @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}}, &px);
    RTCCVPixelBuffer *buffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:px];
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) {
      int64_t ns = (int64_t)(CACurrentMediaTime() * 1e9);
      [source capturer:capturer
          didCaptureVideoFrame:[[RTCVideoFrame alloc] initWithBuffer:buffer
                                                            rotation:RTCVideoRotation_0
                                                         timeStampNs:ns]];
    }];
    Spin(4, nil);
    NSLog(@"ice a=%ld b=%ld pc b=%ld", (long)a.iceConnectionState, (long)b.iceConnectionState, (long)b.connectionState);

    RTCRtpReceiver *r = nil;
    for (RTCRtpTransceiver *t in b.transceivers) if ([t.mid isEqualToString:@"0"]) r = t.receiver;
    NSDictionary *s0 = InboundVideo(b, r);
    NSLog(@"connected: %@, frames decoded: %@, estimatedPlayoutTimestamp: %@",
          b.connectionState == RTCPeerConnectionStateConnected ? @"yes" : @"NO",
          s0[@"framesDecoded"], s0[@"estimatedPlayoutTimestamp"] ?: @"MISSING");
    Spin(2, nil);
    NSDictionary *s1 = InboundVideo(b, r);
    NSLog(@"baseline target delay: %.0f ms", TargetMs(s0, s1));

    SetMinimumDelayOn(r, 0.6);
    Spin(3, nil);
    NSDictionary *s2 = InboundVideo(b, r);
    Spin(2, nil);
    NSDictionary *s3 = InboundVideo(b, r);
    double held = TargetMs(s2, s3);
    NSLog(@"with 600 ms minimum: %.0f ms", held);

    SetMinimumDelayOn(r, std::nullopt);
    Spin(4, nil);
    NSDictionary *s4 = InboundVideo(b, r);
    Spin(2, nil);
    NSDictionary *s5 = InboundVideo(b, r);
    NSLog(@"cleared: %.0f ms", TargetMs(s4, s5));

    Spin(8, nil);
    NSDictionary *late = InboundVideo(b, r);
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *k in late) {
      NSString *l = k.lowercaseString;
      if ([l containsString:@"playout"] || [l containsString:@"ntp"] || [l containsString:@"timestamp"]) [keys addObject:k];
    }
    NSLog(@"after 20 s — estimatedPlayoutTimestamp: %@; timing keys: %@",
          late[@"estimatedPlayoutTimestamp"] ?: @"MISSING", [keys componentsJoinedByString:@", "]);
    [timer invalidate];
    [a close];
    [b close];
    CVPixelBufferRelease(px);
    BOOL ok = held >= 500;
    NSLog(@"%@", ok ? @"PROBE PASS — the hook moves the jitter buffer" : @"PROBE FAIL — delay had no effect");
    return ok ? 0 : 1;
  }
}
