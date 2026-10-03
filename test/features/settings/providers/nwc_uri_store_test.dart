import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/settings/providers/nwc_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uriA =
    'nostr+walletconnect://b889ff5b1513b641e2a139f661a661364979c5beee91842f8f0ef42ab558e9d4?relay=wss%3A%2F%2Frelay.example&secret=71a8c14c1407c113601079c4302dab36460f0ccd0ad506f1f2dc73b5100e4f3c';

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'the URI is saved, but never in SharedPreferences in plain text',
    () async {
      final prefs = await _prefs();
      final notifier = NwcNotifier(store: NwcUriStore(prefs: prefs));

      await notifier.setConnected(
        NwcWalletState(walletPubkey: 'pk', relayUrls: const []),
        nwcUri: _uriA,
      );

      expect(
        prefs.getString(kNwcUriKey),
        isNull,
        reason: 'the connection secret must not sit in plain text',
      );
      expect(
        await NwcUriStore(prefs: prefs).load(),
        _uriA,
        reason: 'and it still survives a restart',
      );
    },
  );
}
