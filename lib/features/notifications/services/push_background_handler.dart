/// The FCM background handler, and the one thing it may do.
///
/// Display-only, by rule (docs/PUSH_NOTIFICATIONS.md §6 principle 2, issue
/// #308): the OS renders the server's content-free notification; this
/// handler never initialises the Rust core, never opens the database and
/// never decrypts. It records that a wake arrived, and the resume path —
/// `resync()` in Rust, then hydration — does every write, once, in the
/// foreground. A test reads this file's imports to hold that boundary.
library;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Set by the handler, cleared by the next resume. A flag, not a counter:
/// ten pushes cost one resync.
const kPushWakePendingKey = 'push_wake_pending';

/// Runs in its own isolate when a push arrives while the app is in the
/// background (docs/PUSH_NOTIFICATIONS.md §7.2). Top-level and pinned, as
/// `firebase_messaging` requires.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  debugPrint('[push] background wake: ${message.data['type']}');
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPushWakePendingKey, true);
  } catch (e) {
    // Diagnostic only: the resume resyncs whether or not the flag is set.
    debugPrint('[push] wake flag not recorded: $e');
  }
}

/// Whether a wake arrived since the last resume, clearing the flag.
Future<bool> consumeWakePending() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getBool(kPushWakePendingKey) ?? false;
    if (pending) await prefs.remove(kPushWakePendingKey);
    return pending;
  } catch (e) {
    debugPrint('[push] wake flag not read: $e');
    return false;
  }
}
