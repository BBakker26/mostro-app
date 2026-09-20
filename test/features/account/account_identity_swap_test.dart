import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mostro/core/app_routes.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/core/automation/automation_ids.dart';
import 'package:mostro/core/services/identity_service.dart';
import 'package:mostro/features/account/providers/backup_reminder_provider.dart';
import 'package:mostro/features/account/providers/privacy_mode_provider.dart';
import 'package:mostro/features/account/screens/account_screen.dart';
import 'package:mostro/l10n/app_localizations.dart';

/// What the backup state is after an identity swap: generating a mnemonic
/// arms the reminder, importing one the user already holds must not (#530).
const _seed =
    'prefer olympic float negative alarm mechanic '
    'capital because sausage struggle travel trade';

/// The screen under test, at `/key_management`, with the bridge-backed
/// identity work replaced by the seams and every other provider it reads
/// pinned to a synchronous value.
Future<ProviderContainer> _pumpAccount(
  WidgetTester tester, {
  required bool reminderArmed,
  required bool backedUp,
  Future<void> Function()? onRegenerate,
  Future<void> Function(List<String> words)? onImport,
}) async {
  tester.view.physicalSize = const Size(360, 760);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      backupReminderProvider.overrideWith(
        (ref) => BackupReminderNotifier(initialValue: reminderArmed),
      ),
      backupCompletedProvider.overrideWith(
        (ref) => BackupCompletedNotifier(initialValue: backedUp),
      ),
      privacyModeProvider.overrideWith(
        (ref) => PrivacyModeNotifier(initialValue: false),
      ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: AppRoute.keyManagement,
    routes: [
      GoRoute(
        path: AppRoute.home,
        builder: (_, __) => const Scaffold(body: Text('home')),
      ),
      GoRoute(
        path: AppRoute.keyManagement,
        builder:
            (_, __) => AccountScreen(
              debugWords: _seed.split(' '),
              debugPublicKey: () async => null,
              debugRegenerate: onRegenerate ?? () async {},
              debugImport: onImport ?? (_) async {},
              debugRecover: () async => const RecoveryOutcome.skipped(),
            ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildDarkTheme(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _import(WidgetTester tester, AppLocalizations l10n) async {
  await tester.tap(find.bySemanticsIdentifier(AutomationIds.keysImport));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), _seed);
  await tester.tap(find.widgetWithText(FilledButton, l10n.importButtonLabel));
  await tester.pumpAndSettle();
}

Future<void> _generate(WidgetTester tester) async {
  await tester.tap(find.bySemanticsIdentifier(AutomationIds.keysGenerate));
  await tester.pumpAndSettle();
  await tester.tap(
    find.bySemanticsIdentifier(AutomationIds.keysGenerateConfirm),
  );
  await tester.pumpAndSettle();
}

void main() {
  late AppLocalizations l10n;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // What the walkthrough leaves behind on first run.
      kBackupReminderActiveKey: true,
      kBackupReminderDismissedKey: false,
    });
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('importing a seed', () {
    testWidgets('clears the reminder armed by the walkthrough', (tester) async {
      final container = await _pumpAccount(
        tester,
        reminderArmed: true,
        backedUp: false,
      );

      await _import(tester, l10n);

      expect(container.read(backupReminderProvider), isFalse);
      expect(container.read(backupCompletedProvider), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBackupReminderDismissedKey), isTrue);
      expect(prefs.getBool(kBackupCompletedKey), isTrue);
    });

    testWidgets('passes the typed words on and lands home', (tester) async {
      List<String>? imported;
      await _pumpAccount(
        tester,
        reminderArmed: true,
        backedUp: false,
        onImport: (words) async => imported = words,
      );

      await _import(tester, l10n);

      expect(imported, _seed.split(' '));
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('a failed import leaves the reminder alone', (tester) async {
      final container = await _pumpAccount(
        tester,
        reminderArmed: true,
        backedUp: false,
        onImport: (_) async => throw StateError('invalid mnemonic'),
      );

      await _import(tester, l10n);

      expect(container.read(backupReminderProvider), isTrue);
      expect(container.read(backupCompletedProvider), isFalse);
    });
  });

  group('generating a new identity', () {
    testWidgets('still arms the reminder and clears the backed-up flag', (
      tester,
    ) async {
      final container = await _pumpAccount(
        tester,
        reminderArmed: false,
        backedUp: true,
      );

      await _generate(tester);

      expect(container.read(backupReminderProvider), isTrue);
      expect(container.read(backupCompletedProvider), isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBackupReminderActiveKey), isTrue);
      expect(prefs.getBool(kBackupReminderDismissedKey), isFalse);
      expect(prefs.getBool(kBackupCompletedKey), isFalse);
    });
  });
}
