import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_notepad/data/app_paths.dart';
import 'package:shared_notepad/data/note_store.dart';
import 'package:shared_notepad/data/pairing.dart';
import 'package:shared_notepad/sync/cloud_sync.dart';

/// In-process stand-in for the Cloudflare Worker, implementing the same
/// contract as `worker/src/index.js`.
class FakeRelay {
  late HttpServer _server;
  final Map<String, String> _pads = {}; // padId -> secret
  final Map<String, Map<String, ({String blob, int updatedAt})>> _slots = {};

  int putCount = 0;
  int getCount = 0;
  int _clock = 1000;

  late final String url;
  bool _stopped = false;

  static Future<FakeRelay> start() async {
    final relay = FakeRelay();
    relay._server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Captured up front so the address survives the server being shut down.
    relay.url = 'http://${relay._server.address.address}:${relay._server.port}';
    relay._server.listen(relay._handle);
    return relay;
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _server.close(force: true);
  }

  Future<void> _reply(HttpRequest req, int status, Object body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final parts = req.uri.pathSegments;

    if (req.uri.path == '/health') return _reply(req, 200, {'ok': true});

    if (req.method == 'POST' && parts.length == 2 && parts[1] == 'pads') {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      final padId = body['padId'] as String;
      final secret = body['secret'] as String;
      final existing = _pads[padId];
      if (existing != null && existing != secret) {
        return _reply(req, 409, {'error': 'pad already exists'});
      }
      _pads[padId] = secret;
      return _reply(req, existing == null ? 201 : 200, {'padId': padId});
    }

    if (parts.length >= 4 && parts[1] == 'pads' && parts[3] == 'slots') {
      final padId = parts[2];
      final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
      final secret = auth.startsWith('Bearer ') ? auth.substring(7) : null;
      if (!_pads.containsKey(padId)) return _reply(req, 404, {'error': 'no such pad'});
      if (secret != _pads[padId]) return _reply(req, 403, {'error': 'bad secret'});

      if (req.method == 'PUT' && parts.length == 5) {
        putCount++;
        final blob = await utf8.decoder.bind(req).join();
        _slots.putIfAbsent(padId, () => {})[parts[4]] = (blob: blob, updatedAt: ++_clock);
        return _reply(req, 200, {'updatedAt': _clock});
      }

      if (req.method == 'GET' && parts.length == 4) {
        getCount++;
        final since = int.tryParse(req.uri.queryParameters['since'] ?? '0') ?? 0;
        final exclude = req.uri.queryParameters['exclude'] ?? '';
        final slots = (_slots[padId] ?? {})
            .entries
            .where((e) => e.key != exclude && e.value.updatedAt >= since)
            .map((e) => {
                  'deviceId': e.key,
                  'updatedAt': e.value.updatedAt,
                  'notes': (jsonDecode(e.value.blob) as Map<String, dynamic>)['notes'] ?? [],
                })
            .toList();
        return _reply(req, 200, {'now': _clock, 'slots': slots});
      }
    }

    return _reply(req, 404, {'error': 'not found'});
  }
}

Future<NoteStore> storeIn(String name) async {
  final dir = await Directory.systemTemp.createTemp('snp_cloud_$name');
  AppPaths.overrideForTests(dir);
  final s = NoteStore();
  await s.load();
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRelay relay;
  late Pairing pad;
  late NoteStore hisStore;
  late NoteStore herStore;
  late CloudSync his;
  late CloudSync hers;

  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    relay = await FakeRelay.start();
    pad = const Pairing(deviceId: 'seed', padId: '', secret: '').createPad();

    hisStore = await storeIn('his');
    herStore = await storeIn('hers');
    his = CloudSync(
      store: hisStore,
      pairing: Pairing(
          deviceId: 'dev1', padId: pad.padId, secret: pad.secret, relayUrl: relay.url),
    );
    hers = CloudSync(
      store: herStore,
      pairing: Pairing(
          deviceId: 'dev2', padId: pad.padId, secret: pad.secret, relayUrl: relay.url),
    );
  });

  tearDown(() async {
    await relay.stop();
    hisStore.dispose();
    herStore.dispose();
  });

  test('a note posted by one phone is picked up by the other', () async {
    hisStore.put(hisStore.createNote().copyWith(title: 'Buy a ladder'));
    await his.sync();

    await hers.sync();

    expect(herStore.notes.single.title, 'Buy a ladder');
  });

  test('the phones never need to be online at the same time', () async {
    // He edits and pushes, then goes offline entirely.
    hisStore.put(hisStore.createNote().copyWith(title: 'Left in the mailbox'));
    await his.sync();

    // She picks it up later with no contact between the two phones.
    await hers.sync();
    herStore.put(herStore.notes.single.copyWith(title: 'Collected and edited'));
    await hers.sync();

    // He comes back and sees her change.
    await his.sync();
    expect(hisStore.notes.single.title, 'Collected and edited');
  });

  test('polling when nothing changed costs no writes', () async {
    hisStore.put(hisStore.createNote().copyWith(title: 'One edit'));
    await his.sync();
    final writesAfterFirst = relay.putCount;

    await his.sync();
    await his.sync();

    expect(relay.putCount, writesAfterFirst, reason: 'idle polls must not re-upload');
    expect(relay.getCount, greaterThan(1), reason: 'but it still checks for updates');
  });

  test('a fresh local edit is pushed again', () async {
    hisStore.put(hisStore.createNote().copyWith(title: 'First'));
    await his.sync();
    final before = relay.putCount;

    hisStore.put(hisStore.createNote().copyWith(title: 'Second'));
    await his.sync();

    expect(relay.putCount, before + 1);
  });

  test('concurrent edits merge instead of overwriting', () async {
    hisStore.put(hisStore.createNote(isChecklist: true).copyWith(title: 'Groceries'));
    await his.sync();
    await hers.sync();

    // She ticks nothing but renames; he adds a separate note. Both should live.
    herStore.put(herStore.notes.single.copyWith(title: 'Costco'));
    hisStore.put(hisStore.createNote().copyWith(title: 'Hardware store'));

    await hers.sync();
    await his.sync();
    await hers.sync();

    for (final store in [hisStore, herStore]) {
      expect(store.notes.map((n) => n.title), containsAll(['Costco', 'Hardware store']));
    }
  });

  test('a phone with the wrong secret cannot read the pad', () async {
    hisStore.put(hisStore.createNote().copyWith(title: 'Private'));
    await his.sync();

    final intruderStore = await storeIn('intruder');
    addTearDown(intruderStore.dispose);
    final intruder = CloudSync(
      store: intruderStore,
      pairing: Pairing(
          deviceId: 'dev9', padId: pad.padId, secret: 'wrong-secret', relayUrl: relay.url),
    );

    await intruder.sync();

    expect(intruderStore.notes, isEmpty);
  });

  test('an unreachable relay degrades gracefully instead of throwing', () async {
    await relay.stop();

    final message = await his.sync();

    expect(message, isNotNull);
    expect(message, contains('saved on this phone'));
  });

  test('no relay configured means the cloud path stays out of the way', () async {
    final offline = CloudSync(
      store: hisStore,
      pairing: Pairing(deviceId: 'dev1', padId: pad.padId, secret: pad.secret),
    );

    expect(offline.enabled, isFalse);
    expect(await offline.sync(), isNull);
  });

  test('probe accepts a live relay and rejects a dead address', () async {
    expect(await CloudSync.probe(relay.url), isTrue);
    await relay.stop();
    expect(await CloudSync.probe(relay.url), isFalse);
  });

  test('the pairing code carries the relay address to the other phone', () {
    final withRelay = pad.withRelayUrl('https://relay.example.workers.dev/');
    final decoded = Pairing.decodePairCode(withRelay.pairCode);

    expect(decoded!.relayUrl, 'https://relay.example.workers.dev');
    expect(decoded.padId, pad.padId);
  });
}
