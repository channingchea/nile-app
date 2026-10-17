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
  result(FlutterMethodNotImplemented);
}

@end
