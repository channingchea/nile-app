import 'package:livekit_client/livekit_client.dart';

/// What a free show publishes: 480p at about 800 kbps, instead of the 720p
/// default (docs/plans/cost-controls-and-60-payout.md, phase 3). Viewer
/// bandwidth is the cost of a show nobody paid for, and bitrate is what sets
/// it. The server says which shows are free — `freeShow` on publisher tokens.
class FreeShowVideo {
  FreeShowVideo._();

  static const _bitrate = 800 * 1000;

  static const params = VideoParameters(
    dimensions: VideoDimensions(854, 480),
    encoding: VideoEncoding(maxBitrate: _bitrate, maxFramerate: 30),
  );

  /// Camera capture size for a show that is [free] or not.
  static VideoParameters capture(bool free) =>
      free ? params : VideoParametersPresets.h720_169;

  /// A room's publish defaults. A free show's screen share keeps its size (it
  /// has to stay readable) and is held to the same bitrate instead.
  static VideoPublishOptions publish(bool free) => free
      ? VideoPublishOptions(
          videoEncoding: params.encoding,
          screenShareEncoding: const VideoEncoding(
            maxBitrate: _bitrate,
            maxFramerate: 15,
          ),
        )
      : const VideoPublishOptions();
}
