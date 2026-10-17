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

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
