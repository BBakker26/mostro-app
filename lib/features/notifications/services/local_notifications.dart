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

/// The one notification the app renders itself: a peer's chat message woke
/// it. A fixed id and tag, so a burst of wakes replaces one notice instead
/// of stacking several.
const kChatWakeNotificationId = 38400;
const _kChatWakeTag = 'mostro-chat';

Future<void> _initialize() => _plugin.initialize(
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

/// Show the content-free "new message" notice (docs/PUSH_NOTIFICATIONS.md
/// §7.2, T3.2). Callable from the background isolate: it initialises its own
/// plugin instance there. [title] and [body] never name a trade, a peer or
/// the message.
Future<void> showChatWakeNotification(String title, String body) async {
  if (kIsWeb) return;
  await _initialize();
  await _plugin.show(
    kChatWakeNotificationId,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        kPushChannelId,
        kPushChannelName,
        importance: Importance.high,
        priority: Priority.high,
        tag: _kChatWakeTag,
      ),
      iOS: DarwinNotificationDetails(threadIdentifier: _kChatWakeTag),
    ),
  );
}

/// Create the channel with the importance the app wants, once per launch.
/// Idempotent on the platform side; failures are logged, since a missing
/// channel degrades the notification's importance but never its delivery.
Future<void> ensurePushNotificationChannel() async {
  if (kIsWeb) return;
  try {
    await _initialize();
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
}
