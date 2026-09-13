import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mostro/features/chat/providers/chat_providers.dart';
import 'package:mostro/features/disputes/providers/disputes_providers.dart';
import 'package:mostro/features/notifications/providers/notifications_provider.dart';
import 'package:mostro/features/trades/providers/trades_providers.dart';
import 'package:mostro/src/rust/api/nostr.dart' as nostr_api;
import 'package:mostro/src/rust/api/types.dart';

/// One hydration hook: re-read a feature's protocol state from the bridge.
///
/// **Streams are for live updates; queries are for hydration. Resume always
/// re-hydrates.** A notifier fed only by incremental events silently loses
/// everything that happened while the process was suspended, and a
/// hand-maintained list of per-feature refresh calls is exactly what let v1
/// ship the dispute-chat bug (MostroP2P/mobile#675). So a feature exposes the
/// same code path it uses at cold start, and resume runs all of them.
typedef Hydrator = Future<void> Function(ProviderContainer container);

/// The resume routine: `resync()` in Rust, then every hydrator, in order.
///
/// Pure enough to test with fakes: the bridge call and the hook list are
/// injected. Each step is isolated — a hydrator that throws is logged and
/// the next one still runs, and a failed resync still hydrates (whatever is
/// already on disk is newer than what the notifiers hold).
class ResumeResync {
  ResumeResync({
    required this.container,
    Future<ResyncOutcome> Function()? resync,
    List<Hydrator>? hydrators,
  }) : _resync = resync ?? nostr_api.resync,
       _hydrators = hydrators ?? defaultHydrators;

  final ProviderContainer container;
  final Future<ResyncOutcome> Function() _resync;
  final List<Hydrator> _hydrators;

  Future<void> run() async {
    try {
      final outcome = await _resync();
      debugPrint(
        '[lifecycle] resync: online=${outcome.online} '
        'flushed=${outcome.flushed} coalesced=${outcome.coalesced}',
      );
    } catch (e) {
      debugPrint('[lifecycle] resync failed: $e');
    }
    for (final hydrate in _hydrators) {
      try {
        await hydrate(container);
      } catch (e, st) {
        debugPrint('[lifecycle] hydration failed: $e\n$st');
      }
    }
  }
}

/// Every notifier that holds protocol-derived state, in dependency order:
/// trades first, since chat rooms and disputes are read off the trade list.
final List<Hydrator> defaultHydrators = [
  hydrateTrades,
  hydrateChatRooms,
  hydrateDisputes,
  hydrateNotifications,
];
