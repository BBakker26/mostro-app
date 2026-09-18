import 'package:flutter/widgets.dart';

import 'package:mostro/features/home/providers/home_order_providers.dart';

/// Slowest horizontal release, in logical pixels per second, that counts as a
/// swipe. Below it a drag was hesitant or diagonal and changes nothing.
const double minSideSwipeVelocity = 300;

/// The side a horizontal swipe with [velocity] leads to from [current], or
/// null when it leads nowhere.
///
/// The swipe moves like the Buy | Sell tabs are laid out: a swipe to the left
/// (negative velocity) brings in the tab on the right, Sell; a swipe to the
/// right brings back Buy. Swiping past the last tab does nothing.
OrderType? sideAfterSwipe(OrderType current, double velocity) {
  if (velocity.abs() < minSideSwipeVelocity) return null;
  final next = velocity < 0 ? OrderType.sell : OrderType.buy;
  return next == current ? null : next;
}

/// Switches the order book between Buy and Sell on a horizontal swipe over
/// [child], so the thumb never has to reach the tabs at the top.
///
/// Only a horizontal drag is claimed: a vertical one still scrolls the list.
class SideSwipe extends StatelessWidget {
  const SideSwipe({
    super.key,
    required this.current,
    required this.onChanged,
    required this.child,
  });

  final OrderType current;
  final ValueChanged<OrderType> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Swipes that start between cards count too.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (details) {
        final next = sideAfterSwipe(current, details.primaryVelocity ?? 0);
        if (next != null) onChanged(next);
      },
      child: child,
    );
  }
}
