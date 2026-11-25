import 'package:flutter_test/flutter_test.dart';
import 'package:nile_realsync/nile_realsync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no native side → unavailable, and calls are refused, never thrown', () async {
    expect(await NileRealSync.unavailableReason(), 'unsupported platform');
    expect(
      await NileRealSync.setMinimumPlayoutDelay('r1', const Duration(milliseconds: 120)),
      isFalse,
    );
  });
}
