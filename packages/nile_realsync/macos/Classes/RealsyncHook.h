// The C++ half of RealSync (see RealsyncHook.mm), behind a C interface so the
// plugin class can stay plain Objective-C — Xcode auto-links Flutter for .m
// files, not for Objective-C++.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Why the hook can't be used on this binary, or nil when it can. Cached.
NSString *_Nullable NileRealsyncUnavailableReason(void);

/// Set (seconds >= 0) or clear (seconds < 0) the minimum playout delay of
/// flutter_webrtc's receiver with this id. NO if it wasn't found.
BOOL NileRealsyncSetMinimumDelay(NSString *receiverId, double seconds);

/// Why capture stamps can't be used on this binary, or nil. Cached.
NSString *_Nullable NileRealsyncStampUnavailableReason(void);

/// Stamp every frame flutter_webrtc's sender with this id sends.
BOOL NileRealsyncStampSender(NSString *senderId, BOOL audio);

/// Read stamps arriving at flutter_webrtc's receiver with this id.
BOOL NileRealsyncReadReceiver(NSString *receiverId, BOOL audio);

/// Detach from a sender/receiver and drop its readings.
void NileRealsyncForget(NSString *nativeId);

/// receiverId → @{ageMs, count} for receivers with recent stamped frames.
NSDictionary *NileRealsyncAges(NSArray *receiverIds, int windowMs);

/// Frames stamped so far by a sender (-1 if it isn't stamping).
long long NileRealsyncStampedCount(NSString *senderId);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
