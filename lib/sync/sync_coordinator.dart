import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/note_store.dart';
import '../data/pairing.dart';
import '../models/note.dart';
import 'cloud_sync.dart';
import 'sync_service.dart';

/// Runs both ways of reaching the other phone and presents them as one thing.
///
/// Wi-Fi is tried first: when you are both home it is instant and costs
/// nothing. The Cloudflare relay covers everywhere else, and also removes the
/// need for both apps to be open at the same moment — one phone leaves its
/// notes in the mailbox, the other collects them whenever it next opens.
///
/// Both paths end in the same merge function, so it does not matter which one
/// delivers an edit, or whether both do.
class SyncCoordinator {
  final NoteStore store;
  final SyncService lan;
  final CloudSync cloud;

  Pairing pairing;

  final ValueNotifier<SyncStatus> status = ValueNotifier(const SyncStatus());

  Timer? _periodic;
  Timer? _pushDebounce;
  bool _running = false;

  SyncCoordinator({required this.store, required this.pairing})
      : lan = SyncService(store: store, pairing: pairing),
        cloud = CloudSync(store: store, pairing: pairing);

  Future<void> start() async {
    await lan.start(enableTimer: false);
    _periodic?.cancel();
    if (pairing.isPaired) {
      _periodic = Timer.periodic(const Duration(seconds: 20), (_) => unawaited(syncNow()));
      unawaited(syncNow());
    } else {
      status.value = const SyncStatus(message: 'Not paired yet');
    }
  }

  Future<void> stop() async {
    _periodic?.cancel();
    _periodic = null;
    _pushDebounce?.cancel();
    _pushDebounce = null;
    await lan.stop();
  }

  Future<void> restartWith(Pairing next) async {
    await stop();
    pairing = next;
    lan.pairing = next;
    cloud.reset(next);
    await start();
  }

  /// Called on every local edit; coalesces a burst of typing into one push.
  void schedulePush() {
    _pushDebounce?.cancel();
    _pushDebounce = Timer(const Duration(seconds: 2), () => unawaited(syncNow()));
  }

  Future<void> syncNow() async {
    if (!pairing.isPaired || _running) return;
    _running = true;
    status.value = SyncStatus(
      message: 'Syncing…',
      lastSyncedAt: status.value.lastSyncedAt,
      busy: true,
    );
    try {
      await lan.syncNow();
      final lanStatus = lan.status.value;
      final lanWorked = lanStatus.lastSyncedAt != null &&
          lanStatus.lastSyncedAt! > (nowMs() - const Duration(seconds: 30).inMilliseconds);

      final cloudMessage = await cloud.sync();

      if (lanWorked) {
        status.value = SyncStatus(message: 'Synced over Wi-Fi', lastSyncedAt: nowMs());
      } else if (cloudMessage != null && _cloudReachable(cloudMessage)) {
        status.value = SyncStatus(message: cloudMessage, lastSyncedAt: nowMs());
      } else {
        status.value = SyncStatus(
          message: cloudMessage ?? 'Partner not on this Wi-Fi — saved here',
          lastSyncedAt: status.value.lastSyncedAt,
        );
      }
    } finally {
      _running = false;
    }
  }

  static bool _cloudReachable(String message) =>
      message == 'Up to date' ||
      message == 'Sent to the relay' ||
      message == 'Updated from your partner';

  void dispose() {
    unawaited(stop());
    status.dispose();
  }
}
