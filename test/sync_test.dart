import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_notepad/data/app_paths.dart';
import 'package:shared_notepad/data/note_store.dart';
import 'package:shared_notepad/data/pairing.dart';
import 'package:shared_notepad/models/note.dart';
import 'package:shared_notepad/sync/sync_service.dart';

/// Stands up two independent "phones" in one process and syncs them over a
/// real socket, so the wire format, signing and merge all get exercised.
class Phone {
  final Directory dir;
  final NoteStore store;
  final SyncService sync;

  Phone(this.dir, this.store, this.sync);

  static Future<Phone> create(String name, Pairing pairing) async {
    final dir = await Directory.systemTemp.createTemp('snp_$name');
    AppPaths.overrideForTests(dir);
    final store = NoteStore();
    await store.load();
    final sync = SyncService(store: store, pairing: pairing);
    await sync.start(enableDiscovery: false);
    return Phone(dir, store, sync);
  }

  Future<void> dispose() async {
    await sync.stop();
    store.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Phone his;
  late Phone hers;
  late Pairing pad;

  setUpAll(() {
    // flutter_test swaps in an HttpClient that refuses every request. These
    // tests are about real socket traffic, so put the real one back.
    HttpOverrides.global = null;
  });

  setUp(() async {
    pad = const Pairing(deviceId: 'aaaa', padId: '', secret: '').createPad();
    his = await Phone.create('his', Pairing(deviceId: 'dev1', padId: pad.padId, secret: pad.secret));
    hers =
        await Phone.create('hers', Pairing(deviceId: 'dev2', padId: pad.padId, secret: pad.secret));
  });

  tearDown(() async {
    await his.dispose();
    await hers.dispose();
  });

  Future<bool> hisSyncsToHers() =>
      his.sync.syncWithAddress(InternetAddress.loopbackIPv4, hers.sync.httpPort!);

  test('a list made on one phone shows up on the other', () async {
    final list = his.store.createNote(isChecklist: true);
    his.store.put(list.copyWith(title: 'Groceries').upsertItem(
          ChecklistItem.create(text: 'milk', amount: '2', order: 1),
        ));

    expect(await hisSyncsToHers(), isTrue);

    final onHers = hers.store.notes.single;
    expect(onHers.title, 'Groceries');
    expect(onHers.liveItems.single.text, 'milk');
    expect(onHers.liveItems.single.amount, '2');
  });

  test('sync is two-way in a single round trip', () async {
    his.store.put(his.store.createNote().copyWith(title: 'His note'));
    hers.store.put(hers.store.createNote().copyWith(title: 'Her note'));

    expect(await hisSyncsToHers(), isTrue);

    expect(his.store.notes.map((n) => n.title), containsAll(['His note', 'Her note']));
    expect(hers.store.notes.map((n) => n.title), containsAll(['His note', 'Her note']));
  });

  test('crossing an item off at the store survives his edits at home', () async {
    final list = his.store.createNote(isChecklist: true);
    his.store.put(list.copyWith(title: 'Groceries').upsertItem(
          ChecklistItem.create(text: 'milk', order: 1),
        ));
    await hisSyncsToHers();

    // She ticks milk off; meanwhile he renames the list and adds bread.
    final herCopy = hers.store.notes.single;
    hers.store.put(herCopy.upsertItem(herCopy.liveItems.single.copyWith(done: true)));

    final hisCopy = his.store.notes.single;
    his.store.put(hisCopy.copyWith(title: 'Costco').upsertItem(
          ChecklistItem.create(text: 'bread', order: 2),
        ));

    expect(await hisSyncsToHers(), isTrue);

    for (final phone in [his, hers]) {
      final n = phone.store.notes.single;
      expect(n.title, 'Costco');
      expect(n.liveItems.map((i) => i.text), containsAll(['milk', 'bread']));
      expect(n.liveItems.firstWhere((i) => i.text == 'milk').done, isTrue,
          reason: 'her tick must not be lost');
    }
  });

  test('a phone with the wrong secret is turned away', () async {
    final stranger = await Phone.create(
      'stranger',
      Pairing(deviceId: 'dev3', padId: pad.padId, secret: 'not-the-secret'),
    );
    addTearDown(stranger.dispose);

    stranger.store.put(stranger.store.createNote().copyWith(title: 'Intruder'));

    final ok = await stranger.sync.syncWithAddress(
      InternetAddress.loopbackIPv4,
      his.sync.httpPort!,
    );

    expect(ok, isFalse);
    expect(his.store.notes, isEmpty);
  });

  test('a phone on a different pad is turned away', () async {
    final other = const Pairing(deviceId: 'x', padId: '', secret: '').createPad();
    final outsider = await Phone.create(
      'outsider',
      Pairing(deviceId: 'dev4', padId: other.padId, secret: other.secret),
    );
    addTearDown(outsider.dispose);

    outsider.store.put(outsider.store.createNote().copyWith(title: 'Wrong pad'));

    expect(
      await outsider.sync.syncWithAddress(InternetAddress.loopbackIPv4, his.sync.httpPort!),
      isFalse,
    );
    expect(his.store.notes, isEmpty);
  });

  test('deleting a note removes it from the other phone too', () async {
    final n = his.store.createNote();
    his.store.put(n.copyWith(title: 'Temporary'));
    await hisSyncsToHers();
    expect(hers.store.notes, hasLength(1));

    his.store.deleteNote(n.id);
    await hisSyncsToHers();

    expect(hers.store.notes, isEmpty);
  });

  test('syncing twice with no changes leaves both phones alone', () async {
    his.store.put(his.store.createNote().copyWith(title: 'Stable'));
    await hisSyncsToHers();
    final before = hers.store.exportJson();

    await hisSyncsToHers();

    expect(hers.store.exportJson(), before);
  });

  test('an unreachable partner fails cleanly instead of throwing', () async {
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close();

    expect(await his.sync.syncWithAddress(InternetAddress.loopbackIPv4, port), isFalse);
  });

  test('the pairing code round-trips', () {
    final decoded = Pairing.decodePairCode(pad.pairCode);
    expect(decoded, isNotNull);
    expect(decoded!.padId, pad.padId);
    expect(decoded.secret, pad.secret);
    expect(Pairing.decodePairCode('obviously not a code'), isNull);
  });
}
