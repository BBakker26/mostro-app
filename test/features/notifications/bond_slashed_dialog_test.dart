import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mostro/core/app_routes.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/core/automation/automation_id.dart';
import 'package:mostro/core/automation/automation_ids.dart';
import 'package:mostro/features/notifications/models/notification_model.dart';
import 'package:mostro/features/notifications/widgets/bond_slashed_dialog.dart';
import 'package:mostro/l10n/app_localizations.dart';

Finder _byId(String id) =>
    find.byWidgetPredicate((w) => w is AutomationId && w.id == id);

void main() {
  testWidgets('explains the slash and offers the policy', (tester) async {
    final visited = <String>[];
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder:
              (context, _) => Scaffold(
                body: Builder(
                  builder:
                      (context) => TextButton(
                        onPressed:
                            () => BondSlashedDialog.show(
                              context,
                              NotificationModel.bondSlashed(
                                id: 'evt-1',
                                orderId: 'order-1',
                                amountSats: 1648,
                                disputeCause: true,
                                fiatCode: 'USD',
                                fiatAmount: 100,
                                paymentMethod: 'Wire',
                              ),
                            ),
                        child: const Text('open'),
                      ),
                ),
              ),
        ),
        GoRoute(
          path: AppRoute.about,
          builder: (context, _) {
            visited.add('about');
            return const Scaffold(body: Text('about'));
          },
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: router,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Bond slashed'), findsOneWidget);
    expect(
      find.textContaining('forfeited after a dispute resolution'),
      findsOneWidget,
    );
    expect(find.text('Dispute resolution'), findsOneWidget);
    expect(find.text('1648 sats'), findsOneWidget);
    expect(find.text('100 USD'), findsOneWidget);

    await tester.tap(_byId(AutomationIds.bondSlashedViewPolicy));
    await tester.pumpAndSettle();
    expect(visited, ['about']);
    expect(find.text('Bond slashed'), findsNothing);
  });
}
