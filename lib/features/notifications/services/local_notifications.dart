import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The Android channel the push server's visible notification names
/// (docs/PUSH_NOTIFICATIONS.md §3.2, `android.notification.channel_id`).
///
/// If the app never creates it, Android 8+ renders the push on a default
/// channel with default importance, and a user who muted or deleted that
/// channel silences every trade update. The app owns the channel — its
/// importance, sound and vibration — and nothing else about the
/// notification, which the OS renders from the server's payload.
const kPushChannelId = 'mostro_notifications';
const kPushChannelName = 'Mostro';

final FlutterLocalNotificationsPlugin _plugin =
    FlutterLocalNotificationsPlugin();

/// Create the channel with the importance the app wants, once per launch.
/// Idempotent on the platform side; failures are logged, since a missing
/// channel degrades the notification's importance but never its delivery.
///
/// The channel does not need the plugin initialised, so it is created first
/// and on its own: a failed `initialize` (an icon the plugin rejects, say)
/// must not leave the server's push on a default-importance channel.
Future<void> ensurePushNotificationChannel() async {
  if (kIsWeb) return;
  try {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            kPushChannelId,
            kPushChannelName,
            importance: Importance.high,
          ),
        );
  } catch (e) {
    debugPrint('[push] notification channel not created: $e');
  }
  try {
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Permission is asked by the push service, not here.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
  } catch (e) {
    debugPrint('[push] local notifications not initialised: $e');
  }
}
