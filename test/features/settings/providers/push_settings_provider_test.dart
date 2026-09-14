import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/settings/providers/push_settings_provider.dart';
import 'package:mostro/src/rust/api/types.dart' show PushStatus;

import '../../../support/provider_harness.dart';

PushStatus _status({bool enabled = true, int registered = 0}) => PushStatus(
  enabled: enabled,
  hasToken: true,
  registered: registered,
  wanted: registered,
);

/// Records every call, in order, across the bridge and the device.
class _Calls {
  final log = <String>[];
}

class _FakeBridge extends PushBridge {
  _FakeBridge(this.calls, {this.failSet = false, PushStatus? initial})
    : _current = initial ?? _status();

  final _Calls calls;
  final bool failSet;
  PushStatus _current;
  final updates = StreamController<PushStatus>();

  @override
  Future<PushStatus> status() async => _current;

  @override
  Future<void> setEnabled(bool enabled) async {
    calls.log.add('setEnabled($enabled)');
    if (failSet) throw Exception('StorageUnavailable');
    _current = _status(enabled: enabled);
  }

  @override
  Future<Future<PushStatus> Function()> watch() async {
    final queue = StreamIterator(updates.stream);
    return () async {
      await queue.moveNext();
      return queue.current;
    };
  }
}

class _FakeDevice implements PushDevice {
  _FakeDevice(this.calls, {this.failRelease = false});

  final _Calls calls;
  final bool failRelease;

  @override
  Future<void> release() async {
    calls.log.add('release');
    if (failRelease) throw Exception('deleteToken failed');
  }

  @override
  Future<void> reacquire() async => calls.log.add('reacquire');
}

void main() {
  group('PushToggle', () {
    test('off unregisters in Rust first, then lets the token go', () async {
      final calls = _Calls();
      final toggle = PushToggle(
        bridge: _FakeBridge(calls),
        device: _FakeDevice(calls),
      );

      final ok = await toggle.set(false);

      expect(ok, isTrue);
      // The token is still needed to unregister: deleting it first would
      // leave the server holding registrations nobody can take back.
      expect(calls.log, ['setEnabled(false)', 'release']);
    });

    test('on enables in Rust first, then hands a fresh token over', () async {
      final calls = _Calls();
      final toggle = PushToggle(
        bridge: _FakeBridge(calls),
        device: _FakeDevice(calls),
      );

      final ok = await toggle.set(true);

      expect(ok, isTrue);
      expect(calls.log, ['setEnabled(true)', 'reacquire']);
    });

    test(
      'a bridge failure reports false and leaves the device alone',
      () async {
        final calls = _Calls();
        final toggle = PushToggle(
          bridge: _FakeBridge(calls, failSet: true),
          device: _FakeDevice(calls),
        );

        final ok = await toggle.set(false);

        expect(ok, isFalse);
        expect(calls.log, ['setEnabled(false)']);
      },
    );

    test('a device failure does not undo what Rust already did', () async {
      // Rust holds the setting and has already unregistered; a token that
      // could not be deleted is harmless once nothing is registered with it.
      final calls = _Calls();
      final toggle = PushToggle(
        bridge: _FakeBridge(calls),
        device: _FakeDevice(calls, failRelease: true),
      );

      final ok = await toggle.set(false);

      expect(ok, isTrue);
    });

    test('tells the screen to re-read the status once done', () async {
      var changed = 0;
      final calls = _Calls();
      final toggle = PushToggle(
        bridge: _FakeBridge(calls),
        device: _FakeDevice(calls),
        onChanged: () => changed++,
      );

      await toggle.set(false);

      expect(changed, 1);
    });
  });

  group('pushStatusProvider', () {
    test('starts from the persisted status, then follows the stream', () async {
      final calls = _Calls();
      final bridge = _FakeBridge(calls, initial: _status(registered: 1));
      final container = createContainer(
        overrides: [pushBridgeProvider.overrideWithValue(bridge)],
      );
      final seen = <int>[];
      container.listen(pushStatusProvider, (_, next) {
        final status = next.valueOrNull;
        if (status != null) seen.add(status.registered);
      }, fireImmediately: true);

      await Future<void>.delayed(Duration.zero);
      bridge.updates.add(_status(registered: 3));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(seen, [1, 3]);
    });
  });
}
