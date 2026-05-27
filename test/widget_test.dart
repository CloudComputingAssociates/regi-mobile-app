// Smoke test for RegiMenu chat scaffold. The app reads .env at startup which
// is not available in the test runner, so we just verify the entrypoint
// constructor compiles. Real widget tests will follow once services are
// injectable for testing.

import 'package:flutter_test/flutter_test.dart';
import 'package:regi_mobile_appapp.dart';

void main() {
  test('RegiChatApp constructor compiles', () {
    const app = RegiChatApp();
    expect(app, isNotNull);
  });
}
