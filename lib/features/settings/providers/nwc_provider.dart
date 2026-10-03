import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Sentinel for copyWith nullable fields.
const _unset = Object();

/// SharedPreferences key for the persisted NWC URI.
const kNwcUriKey = 'settings.nwcUri';

/// Wallet connection state held in memory.
///
/// `null`  → no wallet connected.
/// non-null → wallet connected; contains pubkey + relay URLs + optional balance.
class NwcWalletState {
  NwcWalletState({
    required this.walletPubkey,
    required List<String> relayUrls,
    this.walletName,
    this.balanceSats,
  }) : relayUrls = List.unmodifiable(relayUrls);

  final String walletPubkey;
  /// Immutable list of NWC relay URLs.
  final List<String> relayUrls;
  final String? walletName;
  final int? balanceSats;

  NwcWalletState copyWith({
    String? walletPubkey,
    List<String>? relayUrls,
    String? walletName,
    Object? balanceSats = _unset,
  }) =>
      NwcWalletState(
        walletPubkey: walletPubkey ?? this.walletPubkey,
        relayUrls: relayUrls ?? this.relayUrls,
        walletName: walletName ?? this.walletName,
        balanceSats: identical(balanceSats, _unset)
            ? this.balanceSats
            : balanceSats as int?,
      );
}

/// Where the NWC URI is kept between launches.
class NwcUriStore {
  NwcUriStore({required SharedPreferences prefs}) : _prefs = prefs;

  final SharedPreferences _prefs;

  Future<void> write(String uri) => _prefs.setString(kNwcUriKey, uri);

  Future<void> delete() => _prefs.remove(kNwcUriKey);

  Future<String?> load() async => _prefs.getString(kNwcUriKey);
}

// ── Notifier ───────────────────────────────────────────────────────────────────

class NwcNotifier extends StateNotifier<NwcWalletState?> {
  NwcNotifier({NwcUriStore? store}) : _store = store, super(null);

  final NwcUriStore? _store;

  /// Store wallet state after a successful `connect_wallet` call.
  /// Persists the NWC URI so it survives app restarts.
  Future<bool> setConnected(NwcWalletState wallet, {String? nwcUri}) async {
    state = wallet;
    if (nwcUri != null) await _store?.write(nwcUri);
    return true;
  }

  /// Clear wallet state after `disconnect_wallet`.
  Future<bool> setDisconnected() async {
    state = null;
    await _store?.delete();
    return true;
  }

  /// Update balance from a `get_balance` result.
  void updateBalance(int? sats) {
    final current = state;
    if (current == null) return;
    state = current.copyWith(balanceSats: sats);
  }
}

// ── Providers ─────────────────────────────────────────────────────────────────

/// Wallet connection state. `null` when no wallet is connected.
/// Override in `main()` via [ProviderScope] to inject [SharedPreferences].
final nwcProvider =
    StateNotifierProvider<NwcNotifier, NwcWalletState?>((ref) => NwcNotifier());

/// Convenience: `true` when a wallet is connected.
final isWalletConnectedProvider = Provider<bool>(
  (ref) => ref.watch(nwcProvider) != null,
);
