#import "NileRealsyncPlugin.h"
#import "RealsyncHook.h"

// Method channel for RealSync. The libwebrtc work is in RealsyncHook.mm.
@implementation NileRealsyncPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
#if TARGET_OS_OSX
  id<FlutterBinaryMessenger> messenger = registrar.messenger;
#else
  id<FlutterBinaryMessenger> messenger = [registrar messenger];
#endif
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"nile_realsync"
                                                              binaryMessenger:messenger];
  [registrar addMethodCallDelegate:[NileRealsyncPlugin new] channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"selfTest"]) {
    NSString *failure = NileRealsyncUnavailableReason();
    result(@{@"ok" : @(failure == nil), @"reason" : failure ?: [NSNull null]});
    return;
  }
  if ([call.method isEqualToString:@"setMinimumPlayoutDelay"]) {
    NSDictionary *args = call.arguments;
    NSString *receiverId = args[@"receiverId"];
    id seconds = args[@"seconds"];
    if (![receiverId isKindOfClass:NSString.class]) {
      result(@NO);
      return;
    }
    double s = [seconds isKindOfClass:NSNumber.class] ? MAX([seconds doubleValue], 0.0) : -1.0;
    result(@(NileRealsyncSetMinimumDelay(receiverId, s)));
    return;
  }
  if ([call.method isEqualToString:@"stampSelfTest"]) {
    NSString *failure = NileRealsyncStampUnavailableReason();
    result(@{@"ok" : @(failure == nil), @"reason" : failure ?: [NSNull null]});
    return;
  }
  NSDictionary *args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  NSString *nativeId = [args[@"id"] isKindOfClass:NSString.class] ? args[@"id"] : nil;
  BOOL audio = [args[@"audio"] boolValue];
  if ([call.method isEqualToString:@"stampSender"]) {
    result(@(nativeId && NileRealsyncStampSender(nativeId, audio)));
    return;
  }
  if ([call.method isEqualToString:@"readReceiver"]) {
    result(@(nativeId && NileRealsyncReadReceiver(nativeId, audio)));
    return;
  }
  if ([call.method isEqualToString:@"forget"]) {
    if (nativeId) NileRealsyncForget(nativeId);
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"ages"]) {
    NSArray *ids = [args[@"ids"] isKindOfClass:NSArray.class] ? args[@"ids"] : @[];
    result(NileRealsyncAges(ids, [args[@"windowMs"] intValue] ?: 1500));
    return;
  }
  if ([call.method isEqualToString:@"stampedCount"]) {
    result(@(nativeId ? NileRealsyncStampedCount(nativeId) : -1));
    return;
  }
  result(FlutterMethodNotImplemented);
}

@end
