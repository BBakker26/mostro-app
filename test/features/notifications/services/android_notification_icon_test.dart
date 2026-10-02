import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/notifications/services/local_notifications.dart';

/// Android draws a notification's small icon from its alpha channel only, so
/// the opaque launcher icon shows as a solid square. Both notifications —
/// the trade update FCM renders and the chat-wake notice the app renders —
/// must name the white silhouette instead.
void main() {
  const resDir = 'android/app/src/main/res';
  const densities = ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'];
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  test('the chat-wake notice uses the notification icon', () {
    expect(kNotificationIcon, '@drawable/ic_notification');
  });

  test('FCM renders the trade update with the same icon', () {
    expect(
      manifest,
      contains(
        'android:name="com.google.firebase.messaging.default_notification_icon"\n'
        '            android:resource="$kNotificationIcon" />',
      ),
    );
  });

  test('FCM falls back to the channel the app creates', () {
    expect(
      manifest,
      contains(
        'android:name="com.google.firebase.messaging.default_notification_channel_id"\n'
        '            android:value="$kPushChannelId" />',
      ),
    );
  });

  test('the icon exists in every density, with an alpha channel', () {
    for (final density in densities) {
      final file = File('$resDir/drawable-$density/ic_notification.png');
      expect(file.existsSync(), isTrue, reason: density);
      // PNG IHDR colour type, byte 25: 6 is RGBA, 4 is grey + alpha.
      final colourType = file.readAsBytesSync()[25];
      expect(colourType, anyOf(4, 6), reason: density);
    }
  });
}
