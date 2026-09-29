import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/about/providers/mostro_node_provider.dart';
import 'package:mostro/features/order/models/invoice_rules.dart';
import 'package:mostro/features/order/providers/invoice_providers.dart';
import 'package:mostro/features/order/providers/trade_state_provider.dart';
import 'package:mostro/features/order/screens/add_lightning_invoice_screen.dart';
import 'package:mostro/features/settings/providers/nwc_provider.dart';
import 'package:mostro/features/trades/providers/trades_providers.dart';
import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/src/rust/api/types.dart' show TradeUpdate;

/// With NWC connected the widget generates the invoice, draws nothing — the
/// screen is expected to leave — and hands it to the submit. When the check
/// refuses it, nothing is sent and nothing moves the screen on: it used to
/// stay blank, with the trade still waiting for an invoice. The buyer must
/// land on the form, holding the generated invoice and the reason.
void main() {
  testWidgets('a generated invoice the check refuses lands on the form', (
    tester,
  ) async {
    // Arrange
    final submissions = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isWalletConnectedProvider.overrideWithValue(true),
          tradeAmountProvider.overrideWith(
            (ref, orderId) => Stream.value(BigInt.from(14634)),
          ),
          tradeUpdatesProvider.overrideWith(
            (ref) => const Stream<TradeUpdate>.empty(),
          ),
          tradeInfoProvider.overrideWith((ref, orderId) async => null),
          mostroNodeProvider.overrideWith((ref) async => null),
          invoiceCheckerProvider.overrideWithValue(
            (request) async => const InvoiceCheckError(
              InvoiceProblem.expiresTooSoon,
              minRemainingSecs: 3600,
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: AddLightningInvoiceScreen(
            orderId: 'order-1',
            generateInvoice: (_) async => 'lnbc146340n1nwcshort',
            submitInvoice: (orderId, invoice, sats) async {
              submissions.add(invoice);
            },
          ),
        ),
      ),
    );

    // Act: the amount, the NWC invoice, the check and the fallback.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Assert
    expect(submissions, isEmpty, reason: 'a refused invoice is never sent');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'lnbc146340n1nwcshort');
    expect(find.textContaining('60 minutes'), findsOneWidget);
  });
}
