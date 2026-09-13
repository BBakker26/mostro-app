import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/core/automation/automation_id.dart';
import 'package:mostro/core/automation/automation_ids.dart';
import 'package:mostro/features/trades/providers/trades_providers.dart';
import 'package:mostro/features/trades/widgets/bond_slashed_notice.dart';
import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/shared/utils/platform_int64.dart';
import 'package:mostro/src/rust/api/types.dart';

import '../../../support/fake_trades.dart';

BondInfo _bond(BondState state) => BondInfo(
  role: BondRole.taker,
  amountSats: BigInt.from(1648),
  invoice: 'lnbc16480n1bond',
  state: state,
  requestedAt: intToPlatformInt64(1000),
  expiresAt: null,
  lockedAt: null,
);

Future<void> _pump(WidgetTester tester, TradeInfo trade) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tradeInfoProvider.overrideWith((ref, id) async => trade)],
      child: MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: BondSlashedNotice(orderId: 'order-1')),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Finder _byId(String id) =>
    find.byWidgetPredicate((w) => w is AutomationId && w.id == id);

void main() {
  testWidgets('nothing unless the bond was slashed', (tester) async {
    await _pump(tester, fakeTrade(bond: _bond(BondState.locked)));
    expect(_byId(AutomationIds.tradeBondSlashed), findsNothing);
  });

  testWidgets('a dispute-cause slash names the dispute', (tester) async {
    await _pump(
      tester,
      fakeTrade(
        status: OrderStatus.settledByAdmin,
        bond: _bond(BondState.slashed),
      ),
    );
    expect(
      find.text('The node slashed your 1648-sat bond in this dispute.'),
      findsOneWidget,
    );
    expect(
      tester.widget<AutomationId>(_byId(AutomationIds.tradeBondSlashed)).label,
      'dispute',
    );
  });

  testWidgets('a timeout slash names the timeout', (tester) async {
    await _pump(
      tester,
      fakeTrade(status: OrderStatus.canceled, bond: _bond(BondState.slashed)),
    );
    expect(find.textContaining('after a step timed out'), findsOneWidget);
    expect(
      tester.widget<AutomationId>(_byId(AutomationIds.tradeBondSlashed)).label,
      'timeout',
    );
  });
}
