import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/lifecycle/resume_resync.dart';
import 'package:mostro/features/chat/providers/chat_providers.dart';
import 'package:mostro/features/disputes/providers/disputes_providers.dart';
import 'package:mostro/features/trades/providers/trades_providers.dart';
import 'package:mostro/src/rust/api/types.dart' as rust_types;

import '../../support/fake_trades.dart';

/// The v1 dispute-chat bug, encoded (MostroP2P/mobile#675, issue #308): a
/// dispute the peer opened and a trade that moved while the process was
/// suspended must be visible after resume, without a restart. The bridge is
/// a mutable fake: what it holds after "suspension" is what the notifiers
/// must show after the resume routine ran.
void main() {
  late List<rust_types.TradeInfo> bridgeTrades;
  late Map<String, rust_types.Dispute> bridgeDisputes;
  late ProviderContainer container;

  ChatRoomState room(String orderId) => ChatRoomState(
    orderId: orderId,
    peerPubkey: 'peer-$orderId',
    peerHandle: 'Peer',
    peerIconIndex: 0,
    peerColorHue: 0,
    isSelling: false,
  );

  setUp(() {
    bridgeTrades = [fakeTrade(id: 't1', status: rust_types.OrderStatus.active)];
    bridgeDisputes = {};
    container = ProviderContainer(
      overrides: [
        rawTradesProvider.overrideWith((ref) async => bridgeTrades.toList()),
        chatRoomsFromTradesProvider.overrideWith((ref) async {
          final trades = await ref.watch(rawTradesProvider.future);
          return [for (final t in trades) room(t.order.id)];
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<rust_types.Dispute?> lookup({required String tradeId}) async =>
      bridgeDisputes[tradeId];

  ResumeResync routine() => ResumeResync(
    container: container,
    resync:
        () async => const rust_types.ResyncOutcome(
          online: true,
          flushed: 0,
          coalesced: false,
        ),
    hydrators: [
      hydrateTrades,
      hydrateChatRooms,
      (c) => hydrateDisputes(c, getDispute: lookup),
    ],
  );

  test(
    'a trade that moved while suspended shows its new status after resume',
    () async {
      // Arrange — cold start read the trade as active.
      expect(
        (await container.read(rawTradesProvider.future)).single.order.status,
        rust_types.OrderStatus.active,
      );

      // "Suspended": the daemon released the escrow.
      bridgeTrades = [
        fakeTrade(id: 't1', status: rust_types.OrderStatus.success),
      ];

      // Act
      await routine().run();

      // Assert
      expect(
        (await container.read(rawTradesProvider.future)).single.order.status,
        rust_types.OrderStatus.success,
      );
    },
  );

  test(
    'a dispute the peer opened while suspended is listed after resume',
    () async {
      // Arrange — nothing disputed at cold start.
      container.read(disputeNotifierProvider);
      expect(container.read(disputeNotifierProvider), isEmpty);

      // "Suspended": the peer opened a dispute; the trade row moved with it.
      bridgeTrades = [
        fakeTrade(id: 't1', status: rust_types.OrderStatus.dispute),
      ];
      bridgeDisputes['order-t1'] = const rust_types.Dispute(
        id: 'd1',
        tradeId: 'order-t1',
        status: rust_types.DisputeStatus.inReview,
        initiatedByMe: false,
        adminPubkey: 'solver',
        openedAt: 1234,
        isRead: false,
      );

      // Act
      await routine().run();

      // Assert
      final listed = container.read(disputeNotifierProvider).single;
      expect(listed.id, 'd1');
      expect(listed.status, DisputeStatus.inReview);
      expect(listed.adminPubkey, 'solver');
      expect(listed.initiatedByMe, isFalse);
    },
  );

  test('re-hydrating a dispute keeps the read flag the user set', () async {
    bridgeTrades = [
      fakeTrade(id: 't1', status: rust_types.OrderStatus.dispute),
    ];
    bridgeDisputes['order-t1'] = const rust_types.Dispute(
      id: 'd1',
      tradeId: 'order-t1',
      status: rust_types.DisputeStatus.open,
      initiatedByMe: true,
      openedAt: 1234,
      isRead: false,
    );
    await routine().run();
    container.read(disputeNotifierProvider.notifier).markRead('d1');

    await routine().run();

    expect(container.read(disputeNotifierProvider).single.isRead, isTrue);
  });

  test(
    'a chat room for a trade that revealed its peer while suspended appears',
    () async {
      expect(container.read(chatRoomsNotifierProvider), isEmpty);

      bridgeTrades = [
        fakeTrade(id: 't1', status: rust_types.OrderStatus.active),
        fakeTrade(id: 't2', status: rust_types.OrderStatus.active),
      ];

      await routine().run();

      expect(
        container.read(chatRoomsNotifierProvider).map((r) => r.orderId),
        unorderedEquals(['order-t1', 'order-t2']),
      );
    },
  );

  test(
    'running the routine twice over an unchanged bridge changes nothing',
    () async {
      await routine().run();
      final before = container.read(chatRoomsNotifierProvider);

      await routine().run();

      expect(container.read(chatRoomsNotifierProvider).length, before.length);
      expect((await container.read(rawTradesProvider.future)).length, 1);
    },
  );
}
