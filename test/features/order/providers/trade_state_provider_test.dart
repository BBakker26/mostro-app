import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/order/providers/trade_state_provider.dart';
import 'package:mostro/src/rust/api/types.dart';

import '../../../support/provider_harness.dart';

void main() {
  testWidgets('polling continues after escrow settles until payout succeeds', (
    tester,
  ) async {
    var lookups = 0;
    final requestedOrders = <String>[];
    final container = createContainer(
      overrides: [
        tradeStatusLookupProvider.overrideWithValue((orderId) async {
          requestedOrders.add(orderId);
          return lookups++ == 0
              ? OrderStatus.settledHoldInvoice
              : OrderStatus.success;
        }),
      ],
    );
    final observed = <OrderStatus>[];
    container.listen<AsyncValue<OrderStatus>>(
      tradeStatusProvider('order-payout'),
      (_, next) {
        if (next.hasValue) observed.add(next.requireValue);
      },
      fireImmediately: true,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump();
    expect(
      container.read(tradeStatusProvider('order-payout')).hasError,
      false,
      reason: container.read(tradeStatusProvider('order-payout')).toString(),
    );
    expect(lookups, 1);
    expect(observed, [OrderStatus.settledHoldInvoice]);
    await tester.pump(const Duration(seconds: 2));
    expect(observed, [OrderStatus.settledHoldInvoice, OrderStatus.success]);
    await tester.pump(const Duration(seconds: 4));
    expect(lookups, 2);
    expect(requestedOrders, ['order-payout', 'order-payout']);
  });

  group('a pushed trade update', () {
    late StreamController<TradeUpdate> updates;
    late OrderStatus current;
    late int lookups;
    late ProviderContainer container;

    setUp(() {
      updates = StreamController<TradeUpdate>.broadcast();
      current = OrderStatus.active;
      lookups = 0;
    });

    tearDown(() => updates.close());

    Future<List<OrderStatus>> observe(WidgetTester tester) async {
      container = createContainer(
        overrides: [
          tradeUpdatesProvider.overrideWith((ref) => updates.stream),
          tradeStatusLookupProvider.overrideWithValue((orderId) async {
            lookups++;
            return current;
          }),
        ],
      );
      final observed = <OrderStatus>[];
      container.listen<AsyncValue<OrderStatus>>(
        tradeStatusProvider('order-1'),
        (_, next) {
          if (next.hasValue) observed.add(next.requireValue);
        },
        fireImmediately: true,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SizedBox(),
        ),
      );
      await tester.pump();
      return observed;
    }

    TradeUpdate update(String orderId, OrderStatus status) =>
        TradeUpdate(orderId: orderId, status: status, occurredAt: 0);

    testWidgets('refreshes the status without waiting for the next poll', (
      tester,
    ) async {
      // Arrange
      final observed = await observe(tester);
      expect(observed, [OrderStatus.active]);

      // Act: the daemon's fiat-sent lands; no poll interval elapses.
      current = OrderStatus.fiatSent;
      updates.add(update('order-1', OrderStatus.fiatSent));
      await tester.pump();
      await tester.pump();

      // Assert
      expect(observed, [OrderStatus.active, OrderStatus.fiatSent]);
      container.dispose();
    });

    testWidgets('for another order does not trigger a lookup', (tester) async {
      // Arrange
      await observe(tester);
      final before = lookups;

      // Act
      updates.add(update('order-2', OrderStatus.fiatSent));
      await tester.pump();
      await tester.pump();

      // Assert
      expect(lookups, before);
      container.dispose();
    });

    testWidgets('reads the status back instead of trusting the payload', (
      tester,
    ) async {
      // Arrange: a history replay re-emits an old transition (#474) while
      // the trade already sits further along.
      current = OrderStatus.fiatSent;
      final observed = await observe(tester);

      final before = lookups;

      // Act
      updates.add(update('order-1', OrderStatus.active));
      await tester.pump();
      await tester.pump();

      // Assert
      expect(lookups, before + 1);
      expect(observed, everyElement(OrderStatus.fiatSent));
      container.dispose();
    });
  });
}
