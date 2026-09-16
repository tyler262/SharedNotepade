import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../data/note_store.dart';
import '../data/pairing.dart';
import '../models/note.dart';

/// Talks to the Cloudflare relay so the phones can sync when they are not on
/// the same Wi-Fi.
///
/// The relay is a mailbox, not an authority. This phone writes its own slot
/// and reads the other phone's, then merges locally with exactly the same
/// merge function the Wi-Fi path uses. Nothing here decides what a note
/// "really" says.
class CloudSync {
  final NoteStore store;
  Pairing pairing;

  /// Watermark from the relay's clock, not ours, so a skewed phone clock
  /// cannot make us skip an update.
  int _since = 0;

  bool _registered = false;

  /// Hash of what we last uploaded. Idle polling re-derives this from the
  /// store rather than relying on anyone remembering to flag an edit, so a
  /// miswired callback can't silently stop pushes.
  String? _lastPushed;

  CloudSync({required this.store, required this.pairing});

  bool get enabled => pairing.isPaired && pairing.hasRelay;

  void reset(Pairing next) {
    pairing = next;
    _since = 0;
    _registered = false;
    _lastPushed = null;
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${pairing.relayUrl}$path').replace(queryParameters: query);

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 5);

  Future<HttpClientResponse> _send(
    HttpClient client,
    String method,
    Uri uri, {
    String? body,
    bool auth = true,
  }) async {
    final req = await client.openUrl(method, uri);
    req.headers.contentType = ContentType.json;
    if (auth) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${pairing.secret}');
    if (body != null) req.write(body);
    return req.close().timeout(const Duration(seconds: 15));
  }

  /// Registering is idempotent, so this can be called freely until it sticks.
  Future<bool> _ensureRegistered(HttpClient client) async {
    if (_registered) return true;
    final res = await _send(
      client,
      'POST',
      _uri('/v1/pads'),
      auth: false,
      body: jsonEncode({'padId': pairing.padId, 'secret': pairing.secret}),
    );
    await res.drain<void>();
    // 409 means the pad exists under a different secret — a genuine mismatch.
    _registered = res.statusCode == 200 || res.statusCode == 201;
    return _registered;
  }

  /// Returns a short status line, or null when the relay is not configured.
  Future<String?> sync() async {
    if (!enabled) return null;
    final client = _client();
    try {
      if (!await _ensureRegistered(client)) {
        return 'Relay rejected this notepad';
      }

      final pulled = await _pull(client);
      final pushed = await _push(client);

      if (pulled > 0) return 'Updated from your partner';
      if (pushed) return 'Sent to the relay';
      return 'Up to date';
    } on TimeoutException {
      return 'Relay timed out';
    } on SocketException {
      return 'No internet — saved on this phone';
    } catch (_) {
      return 'Relay unreachable — saved on this phone';
    } finally {
      client.close(force: true);
    }
  }

  Future<int> _pull(HttpClient client) async {
    final res = await _send(
      client,
      'GET',
      _uri('/v1/pads/${pairing.padId}/slots', {
        'since': '$_since',
        'exclude': pairing.deviceId,
      }),
    );
    if (res.statusCode != HttpStatus.ok) {
      await res.drain<void>();
      return 0;
    }

    final payload = jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, dynamic>;
    final slots = (payload['slots'] as List?) ?? const [];
    var merged = 0;

    for (final slot in slots.cast<Map<String, dynamic>>()) {
      final notes = ((slot['notes'] as List?) ?? const [])
          .map((e) => Note.fromJson(e as Map<String, dynamic>))
          .toList();
      // Merging is idempotent, so re-reading a slot we already have is safe.
      if (store.mergeRemote(notes)) merged++;

      final at = (slot['updatedAt'] as num?)?.toInt() ?? 0;
      if (at > _since) _since = at;
    }
    return merged;
  }

  Future<bool> _push(HttpClient client) async {
    final body = jsonEncode({
      'notes': store.allForSync.map((n) => n.toJson()).toList(),
    });
    final fingerprint = sha256.convert(utf8.encode(body)).toString();
    if (fingerprint == _lastPushed) return false;

    final res = await _send(
      client,
      'PUT',
      _uri('/v1/pads/${pairing.padId}/slots/${pairing.deviceId}'),
      body: body,
    );
    await res.drain<void>();
    if (res.statusCode != HttpStatus.ok) return false;

    _lastPushed = fingerprint;
    return true;
  }

  /// Checks a relay URL before saving it, so a typo is caught during setup.
  static Future<bool> probe(String relayUrl) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('${Pairing.normalizeRelayUrl(relayUrl)}/health'));
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      return res.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
