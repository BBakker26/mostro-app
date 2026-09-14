import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/notifications/services/local_notifications.dart';
import 'package:mostro/features/notifications/services/push_background_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('the background handler is display-only', () {
    test('its file imports no bridge, database, state or navigation code', () {
      // docs/PUSH_NOTIFICATIONS.md §6 principle 2 (issue #308): the push is
      // a doorbell, not a courier. Held down here, where it would rot.
      final source =
          File(
            'lib/features/notifications/services/push_background_handler.dart',
          ).readAsStringSync();
      final imports =
          RegExp(
            r"^import '([^']+)';",
            multiLine: true,
          ).allMatches(source).map((m) => m.group(1)!).toList();

      for (final forbidden in [
        'src/rust/',
        'sembast',
        'sqflite',
        'riverpod',
        'go_router',
        'app_routes',
        'notifications_provider',
        'dart:io',
      ]) {
        expect(
          imports.where((i) => i.contains(forbidden)),
          isEmpty,
          reason: 'the background handler must not import $forbidden',
        );
      }
    });

    test('a wake sets the flag, and the resume consumes it once', () async {
      // Arrange
      SharedPreferences.setMockInitialValues({});
      expect(await consumeWakePending(), isFalse);

      // Act — a push while the app is in the background.
      await pushBackgroundHandler(
        const RemoteMessage(data: {'type': 'trade_update'}),
      );

      // Assert — one flag, consumed once.
      expect(await consumeWakePending(), isTrue);
      expect(await consumeWakePending(), isFalse);
    });

    test('ten pushes cost one resync: the flag is not a counter', () async {
      SharedPreferences.setMockInitialValues({});
      for (var i = 0; i < 10; i++) {
        await pushBackgroundHandler(const RemoteMessage(data: {'type': 'x'}));
      }
      expect(await consumeWakePending(), isTrue);
      expect(await consumeWakePending(), isFalse);
    });
  });

  group('the notification channel', () {
    test('is the one the push server names in its payload', () {
      // The server's listener-path payload sets `channel_id`; the app must
      // own that channel or Android renders the push on a default one.
      final spec = File('docs/PUSH_NOTIFICATIONS.md').readAsStringSync();
      expect(spec, contains('"channel_id": "$kPushChannelId"'));
    });
  });
}
