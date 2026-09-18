import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/home/providers/home_order_providers.dart';
import 'package:mostro/features/home/widgets/side_swipe.dart';

void main() {
  group('sideAfterSwipe', () {
    test('a swipe to the left moves Buy to Sell, the tab on the right', () {
      expect(sideAfterSwipe(OrderType.buy, -800), OrderType.sell);
    });

    test('a swipe to the right moves Sell to Buy, the tab on the left', () {
      expect(sideAfterSwipe(OrderType.sell, 800), OrderType.buy);
    });

    test('a swipe past the last tab stays put', () {
      expect(sideAfterSwipe(OrderType.sell, -800), isNull);
      expect(sideAfterSwipe(OrderType.buy, 800), isNull);
    });

    test('a slow drag is not a swipe', () {
      expect(
        sideAfterSwipe(OrderType.buy, -(minSideSwipeVelocity - 1)),
        isNull,
      );
      expect(sideAfterSwipe(OrderType.sell, minSideSwipeVelocity - 1), isNull);
    });
  });

  group('SideSwipe', () {
    Future<List<OrderType>> pump(WidgetTester tester, OrderType current) async {
      final changes = <OrderType>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SideSwipe(
            current: current,
            onChanged: changes.add,
            // A vertical list underneath, like the order book.
            child: ListView(
              children: [
                for (var i = 0; i < 30; i++)
                  SizedBox(height: 60, child: Text('order $i')),
              ],
            ),
          ),
        ),
      );
      return changes;
    }

    testWidgets('a fling to the left over the list selects Sell', (
      tester,
    ) async {
      final changes = await pump(tester, OrderType.buy);

      await tester.fling(find.text('order 2'), const Offset(-300, 0), 1500);
      await tester.pumpAndSettle();

      expect(changes, [OrderType.sell]);
    });

    testWidgets('a fling to the right over the list selects Buy', (
      tester,
    ) async {
      final changes = await pump(tester, OrderType.sell);

      await tester.fling(find.text('order 2'), const Offset(300, 0), 1500);
      await tester.pumpAndSettle();

      expect(changes, [OrderType.buy]);
    });

    testWidgets(
      'a vertical fling still scrolls the list, and changes nothing',
      (tester) async {
        final changes = await pump(tester, OrderType.buy);

        await tester.fling(find.text('order 2'), const Offset(0, -400), 1500);
        await tester.pumpAndSettle();

        expect(changes, isEmpty);
        expect(find.text('order 0'), findsNothing);
      },
    );
  });
}
