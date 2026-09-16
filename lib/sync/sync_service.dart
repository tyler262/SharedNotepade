import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/note_store.dart';
import '../data/pairing.dart';
import '../models/note.dart';

class SyncStatus {
  final String message;
  final int? lastSyncedAt;
  final bool busy;

  const SyncStatus({this.message = 'Not synced yet', this.lastSyncedAt, this.busy = false});
}

class _Peer {
  final InternetAddress address;
  final int port;
  final String deviceId;
  int lastSeen;

  _Peer(this.address, this.port, this.deviceId) : lastSeen = nowMs();

  String get key => '${address.address}:$port';
}

/// Phone-to-phone sync over the local network. No server, no cloud account.
///
/// Each phone runs a small HTTP endpoint and announces itself over UDP
/// broadcast. When both are on the same Wi-Fi they find each other and trade
/// note sets; the merge is last-write-wins per field, so the exchange is
/// symmetric and converges in a single round trip.
///
/// Every request is signed with the shared pad secret, which is never
/// transmitted. Traffic stays on the LAN and is authenticated but not
/// encrypted — see README.
class SyncService {
  static const int discoveryPort = 51422;
  static const Duration peerTtl = Duration(minutes: 5);

  final NoteStore store;
  Pairing pairing;

  final ValueNotifier<SyncStatus> status = ValueNotifier(const SyncStatus());

  HttpServer? _http;
  RawDatagramSocket? _udp;
  Timer? _periodic;
  Timer? _pushDebounce;
  final Map<String, _Peer> _peers = {};
  bool _syncing = false;

  SyncService({required this.store, required this.pairing});

  int get peerCount {
    _prunePeers();
    return _peers.length;
  }

  List<int> get _key => utf8.encode(pairing.secret);

  String _sign(String body) => Hmac(sha256, _key).convert(utf8.encode(body)).toString();

  bool _verify(String body, String? sig) {
    if (sig == null) return false;
    final expected = _sign(body);
    if (expected.length != sig.length) return false;
    // Constant-time-ish compare.
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ sig.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Port this phone is listening on, or null when sync isn't running.
  int? get httpPort => _http?.port;

  /// [enableDiscovery] is off in tests, where two services share a process and
  /// cannot both own the broadcast port.
  Future<void> start({bool enableDiscovery = true}) async {
    await stop();
    if (!pairing.isPaired) {
      status.value = const SyncStatus(message: 'Not paired yet');
      return;
    }
    try {
      await _startHttp();
      if (enableDiscovery) await _startDiscovery();
      _periodic = Timer.periodic(const Duration(seconds: 20), (_) => unawaited(syncNow()));
      unawaited(syncNow());
    } catch (e) {
      status.value = SyncStatus(message: 'Sync unavailable: $e');
    }
  }

  Future<void> stop() async {
    _periodic?.cancel();
    _periodic = null;
    _pushDebounce?.cancel();
    _pushDebounce = null;
    _udp?.close();
    _udp = null;
    await _http?.close(force: true);
    _http = null;
    _peers.clear();
  }

  Future<void> restartWith(Pairing newPairing) async {
    pairing = newPairing;
    await start();
  }

  /// Called on every local edit; coalesces bursts of typing into one push.
  void schedulePush() {
    _pushDebounce?.cancel();
    _pushDebounce = Timer(const Duration(seconds: 2), () => unawaited(syncNow()));
  }

  // ---------------------------------------------------------------- server

  Future<void> _startHttp() async {
    // Port 0 lets the OS pick a free port; it is advertised over UDP.
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: true);
    _http = server;
    server.listen((req) async {
      try {
        if (req.method != 'POST' || req.uri.path != '/sync') {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        final body = await utf8.decoder.bind(req).join();
        if (!_verify(body, req.headers.value('x-snp-sig'))) {
          req.response.statusCode = HttpStatus.unauthorized;
          await req.response.close();
          return;
        }
        final payload = jsonDecode(body) as Map<String, dynamic>;
        if (payload['pad'] != pairing.padId) {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }

        final incoming = (payload['notes'] as List)
            .map((e) => Note.fromJson(e as Map<String, dynamic>))
            .toList();
        store.mergeRemote(incoming);

        // Reply with our merged set so the caller converges too.
        final reply = jsonEncode({
          'pad': pairing.padId,
          'dev': pairing.deviceId,
          'notes': store.allForSync.map((n) => n.toJson()).toList(),
        });
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..headers.set('x-snp-sig', _sign(reply))
          ..write(reply);
        await req.response.close();
        _touchStatus('Synced with partner');
      } catch (_) {
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          await req.response.close();
        } catch (_) {
          // Client already gone.
        }
      }
    }, onError: (_) {});
  }

  // ------------------------------------------------------------- discovery

  Future<void> _startDiscovery() async {
    final udp = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
      reusePort: false,
    );
    udp.broadcastEnabled = true;
    _udp = udp;

    udp.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = udp.receive();
      if (dg == null) return;
      try {
        final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (msg['pad'] != pairing.padId) return;
        final dev = msg['dev'] as String?;
        if (dev == null || dev == pairing.deviceId) return;
        final port = msg['port'] as int?;
        if (port == null) return;

        final peer = _Peer(dg.address, port, dev);
        _peers[peer.key] = peer;

        if (msg['t'] == 'q') {
          // Someone is looking for peers — answer directly.
          _send(udp, dg.address, {
            't': 'r',
            'pad': pairing.padId,
            'dev': pairing.deviceId,
            'port': _http?.port ?? 0,
          });
        }
        unawaited(_syncWithPeer(peer));
      } catch (_) {
        // Stray packet on the port; ignore.
      }
    }, onError: (_) {});
  }

  void _send(RawDatagramSocket udp, InternetAddress to, Map<String, dynamic> msg) {
    try {
      udp.send(utf8.encode(jsonEncode(msg)), to, discoveryPort);
    } catch (_) {
      // Unreachable interface; other targets may still work.
    }
  }

  Future<void> _broadcastQuery() async {
    final udp = _udp;
    final http = _http;
    if (udp == null || http == null) return;
    final msg = {
      't': 'q',
      'pad': pairing.padId,
      'dev': pairing.deviceId,
      'port': http.port,
    };

    _send(udp, InternetAddress('255.255.255.255'), msg);

    // Some Android builds drop the global broadcast but pass subnet-directed
    // ones, so also aim at the /24 each interface sits on (the near-universal
    // home Wi-Fi layout).
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          _send(udp, InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'), msg);
        }
      }
    } catch (_) {
      // Permission or platform quirk; the global broadcast may still land.
    }
  }

  void _prunePeers() {
    final cutoff = nowMs() - peerTtl.inMilliseconds;
    _peers.removeWhere((_, p) => p.lastSeen < cutoff);
  }

  // ---------------------------------------------------------------- client

  Future<void> syncNow() async {
    if (!pairing.isPaired || _syncing) return;
    _syncing = true;
    status.value = SyncStatus(
      message: 'Looking for your partner…',
      lastSyncedAt: status.value.lastSyncedAt,
      busy: true,
    );
    try {
      await _broadcastQuery();
      _prunePeers();
      final peers = _peers.values.toList();
      var ok = 0;
      for (final p in peers) {
        if (await _syncWithPeer(p)) ok++;
      }
      if (ok > 0) {
        _touchStatus(ok == 1 ? 'Synced with partner' : 'Synced with $ok devices');
      } else {
        status.value = SyncStatus(
          message: peers.isEmpty
              ? 'Partner not on this Wi-Fi — changes saved here'
              : 'Partner unreachable — changes saved here',
          lastSyncedAt: status.value.lastSyncedAt,
        );
      }
    } finally {
      _syncing = false;
    }
  }

  /// Syncs against a known address directly, skipping discovery.
  Future<bool> syncWithAddress(InternetAddress address, int port) =>
      _syncWithPeer(_Peer(address, port, 'direct'));

  Future<bool> _syncWithPeer(_Peer peer) async {
    if (peer.port == 0) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final body = jsonEncode({
        'pad': pairing.padId,
        'dev': pairing.deviceId,
        'notes': store.allForSync.map((n) => n.toJson()).toList(),
      });
      final req = await client
          .postUrl(Uri.parse('http://${peer.address.address}:${peer.port}/sync'))
          .timeout(const Duration(seconds: 4));
      req.headers.contentType = ContentType.json;
      req.headers.set('x-snp-sig', _sign(body));
      req.write(body);
      final res = await req.close().timeout(const Duration(seconds: 6));
      if (res.statusCode != HttpStatus.ok) return false;
      final replyBody = await utf8.decoder.bind(res).join();
      if (!_verify(replyBody, res.headers.value('x-snp-sig'))) return false;

      final payload = jsonDecode(replyBody) as Map<String, dynamic>;
      if (payload['pad'] != pairing.padId) return false;
      final incoming = (payload['notes'] as List)
          .map((e) => Note.fromJson(e as Map<String, dynamic>))
          .toList();
      store.mergeRemote(incoming);
      peer.lastSeen = nowMs();
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void _touchStatus(String message) {
    status.value = SyncStatus(message: message, lastSyncedAt: nowMs());
  }

  void dispose() {
    unawaited(stop());
    status.dispose();
  }
}
