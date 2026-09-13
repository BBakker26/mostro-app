import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/lifecycle/resume_resync.dart';
import 'package:mostro/src/rust/api/types.dart';

void main() {
  const ok = ResyncOutcome(online: true, flushed: 0, coalesced: false);

  late ProviderContainer container;
  late List<String> calls;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    calls = [];
  });

  Hydrator hook(String name, {bool throws = false}) => (c) async {
    expect(identical(c, container), isTrue);
    calls.add(name);
    if (throws) throw StateError('$name failed');
  };

  test('resync runs first, then every hydrator in order', () async {
    // Arrange
    final routine = ResumeResync(
      container: container,
      resync: () async {
        calls.add('resync');
        return ok;
      },
      hydrators: [hook('trades'), hook('chat'), hook('disputes')],
    );

    // Act
    await routine.run();

    // Assert
    expect(calls, ['resync', 'trades', 'chat', 'disputes']);
  });

  test('a hydrator that throws does not stop the ones after it', () async {
    final routine = ResumeResync(
      container: container,
      resync: () async => ok,
      hydrators: [hook('trades'), hook('chat', throws: true), hook('disputes')],
    );

    await routine.run();

    expect(calls, ['trades', 'chat', 'disputes']);
  });

  test('a failed resync still hydrates — disk is newer than memory', () async {
    final routine = ResumeResync(
      container: container,
      resync: () async => throw StateError('no bridge'),
      hydrators: [hook('trades')],
    );

    await expectLater(routine.run(), completes);

    expect(calls, ['trades']);
  });

  test('the default hook list covers every protocol-state notifier', () {
    // Trades first: chat rooms and disputes are read off the trade list.
    expect(defaultHydrators, hasLength(4));
  });
}
