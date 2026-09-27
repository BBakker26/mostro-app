import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/trades/providers/release_pending_provider.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  test('a published release waits until its order moves', () {
    // Arrange
    final notifier = container.read(releasePendingProvider.notifier);

    // Act
    notifier.start('order-a');
    notifier.start('order-b');
    notifier.settle('order-a');

    // Assert
    expect(container.read(releasePendingProvider), {
      'order-b': ReleaseWait.waiting,
    });
  });

  test('settling an order that waits for nothing changes nothing', () {
    final before = container.read(releasePendingProvider);

    container.read(releasePendingProvider.notifier).settle('order-x');

    expect(identical(container.read(releasePendingProvider), before), isTrue);
  });

  // What resetIdentityScopedState does: the next user starts with no
  // release of the previous one waiting.
  test('an identity change forgets every wait', () {
    container.read(releasePendingProvider.notifier).start('order-a');

    container.invalidate(releasePendingProvider);

    expect(container.read(releasePendingProvider), isEmpty);
  });
}
