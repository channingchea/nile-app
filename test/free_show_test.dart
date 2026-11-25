import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:nile_app/services/free_show.dart';
import 'package:nile_app/services/livekit_service.dart';

/// docs/plans/cost-controls-and-60-payout.md, phase 3.
void main() {
  test('a free show publishes 480p at 800 kbps; a paid one is untouched', () {
    final free = FreeShowVideo.capture(true);
    expect([free.dimensions.width, free.dimensions.height], [854, 480]);
    expect(free.encoding!.maxBitrate, 800 * 1000);
    expect(FreeShowVideo.capture(false), VideoParametersPresets.h720_169);

    final publish = FreeShowVideo.publish(true);
    expect(publish.videoEncoding!.maxBitrate, 800 * 1000);
    expect(publish.screenShareEncoding!.maxBitrate, 800 * 1000);
    expect(FreeShowVideo.publish(false).videoEncoding, isNull);
  });

  test('tokens carry freeShow; servers that predate it mean "not free"', () {
    const base = {'token': 't', 'wsUrl': 'w'};
    expect(LivekitToken.fromJson({...base, 'freeShow': true}).freeShow, isTrue);
    expect(LivekitToken.fromJson(base).freeShow, isFalse);
    const guest = {...base, 'identity': 'guest-1', 'status': 'green_room'};
    expect(
      GuestConnection.fromJson({...guest, 'freeShow': true}).freeShow,
      isTrue,
    );
    expect(GuestConnection.fromJson(guest).freeShow, isFalse);
  });
}
