import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mostro/features/notifications/services/push_notification_service.dart';
import 'package:mostro/src/rust/api/push.dart' as push_api;
import 'package:mostro/src/rust/api/types.dart' show PushStatus;

/// 10d's master push toggle and the status line under it
/// (docs/PUSH_NOTIFICATIONS.md §7.4, §9.1).
///
/// Three facts, three sources, never conflated (§8.1): whether this platform
/// can push at all is Dart's ([pushSupportedProvider]); whether the OS lets
/// the app notify is `notificationPermissionDeniedProvider`; everything about
/// registration — the setting, the token Rust holds, what the server has — is
/// Rust's, read here through [pushStatusProvider].

/// The Rust side of the toggle. Injected so screen tests never reach the
/// bridge.
class PushBridge {
  const PushBridge();

  Future<PushStatus> status() => push_api.getPushStatus();

  Future<void> setEnabled(bool enabled) =>
      push_api.setPushEnabled(enabled: enabled);

  /// A reader for the next status. Subscribed before the first [status]
  /// read, so an update landing in between is not missed.
  Future<Future<PushStatus> Function()> watch() async {
    final stream = await push_api.onPushStatusChanged();
    return stream.next;
  }
}

/// The device side of the toggle: the FCM token.
abstract interface class PushDevice {
  /// Delete the device token and stop handing new ones to Rust.
  Future<void> release();

  /// Acquire a token again and hand it to Rust.
  Future<void> reacquire();
}

class _ServiceDevice implements PushDevice {
  const _ServiceDevice();

  @override
  Future<void> release() => PushNotificationService.instance.release();

  @override
  Future<void> reacquire() => PushNotificationService.instance.reacquire();
}

final pushBridgeProvider = Provider<PushBridge>((ref) => const PushBridge());

final pushDeviceProvider = Provider<PushDevice>(
  (ref) => const _ServiceDevice(),
);

/// Whether this platform can receive a push at all — checked before the
/// permission and the token, so a phone that has not handed a token over
/// yet shows the toggle, not unsupported copy.
final pushSupportedProvider = Provider<bool>(
  (ref) => PushNotificationService.instance.isSupported,
);

/// The persisted status, then one per reconcile while the screen is open.
final pushStatusProvider = StreamProvider.autoDispose<PushStatus>((ref) async* {
  final bridge = ref.watch(pushBridgeProvider);
  final next = await bridge.watch();
  yield await bridge.status();
  while (true) {
    yield await next();
  }
});

/// Turns push on or off end to end (§7.4).
///
/// Rust goes first both ways. Off: the unregister needs the token, so the
/// token is let go only after Rust has unregistered everything it knows
/// about. On: Rust clears the node refusals and is ready before the device
/// hands a fresh token over.
class PushToggle {
  PushToggle({
    required PushBridge bridge,
    required PushDevice device,
    VoidCallback? onChanged,
  }) : _bridge = bridge,
       _device = device,
       _onChanged = onChanged;

  final PushBridge _bridge;
  final PushDevice _device;
  final VoidCallback? _onChanged;

  /// False when the setting could not be saved, and nothing changed. A
  /// device-side failure after that is logged, not reported: Rust holds the
  /// setting, and a token nothing is registered with is harmless.
  Future<bool> set(bool enabled) async {
    try {
      await _bridge.setEnabled(enabled);
    } catch (e) {
      debugPrint('[push_settings] setEnabled($enabled) failed: $e');
      return false;
    }
    try {
      if (enabled) {
        await _device.reacquire();
      } else {
        await _device.release();
      }
    } catch (e) {
      debugPrint('[push_settings] device side of the toggle failed: $e');
    }
    _onChanged?.call();
    return true;
  }
}

final pushToggleProvider = Provider<PushToggle>(
  (ref) => PushToggle(
    bridge: ref.watch(pushBridgeProvider),
    device: ref.watch(pushDeviceProvider),
    onChanged: () => ref.invalidate(pushStatusProvider),
  ),
);
