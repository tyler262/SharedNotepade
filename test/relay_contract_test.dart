@Tags(['relay'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_notepad/data/app_paths.dart';
import 'package:shared_notepad/data/note_store.dart';
import 'package:shared_notepad/data/pairing.dart';
import 'package:shared_notepad/models/note.dart';
import 'package:shared_notepad/sync/cloud_sync.dart';

/// Runs the real client against a real instance of `worker/src/index.js`,
/// to prove the Worker and the app actually agree on the wire format.
///
/// Skipped unless a relay is pointed at, so the normal suite stays offline:
///
///   cd worker && npx wrangler dev --local --port 8787
///   SNP_RELAY_URL=http://127.0.0.1:8787 flutter test test/relay_contract_test.dart
void main() {
  final relayUrl = Platform.environment['SNP_RELAY_URL'] ?? '';
  if (relayUrl.isEmpty) {
    test('relay contract (skipped: set SNP_RELAY_URL to run)', () {}, skip: true);
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  late Pairing pad;
  late NoteStore hisStore;
  late NoteStore herStore;
  late CloudSync his;
  late CloudSync hers;

  Future<NoteStore> freshStore(String name) async {
    final dir = await Directory.systemTemp.createTemp('snp_contract_$name');
    AppPaths.overrideForTests(dir);
    final s = NoteStore();
    await s.load();
    return s;
  }

  setUp(() async {
    // A new random pad per test keeps runs independent against a shared relay.
    pad = const Pairing(deviceId: 'seed', padId: '', secret: '').createPad();
    hisStore = await freshStore('his');
    herStore = await freshStore('hers');
    his = CloudSync(
      store: hisStore,
      pairing:
          Pairing(deviceId: 'dev1', padId: pad.padId, secret: pad.secret, relayUrl: relayUrl),
    );
    hers = CloudSync(
      store: herStore,
      pairing:
          Pairing(deviceId: 'dev2', padId: pad.padId, secret: pad.secret, relayUrl: relayUrl),
    );
  });

  tearDown(() {
    hisStore.dispose();
    herStore.dispose();
  });

  test('the relay is reachable', () async {
    expect(await CloudSync.probe(relayUrl), isTrue);
  });

  test('a shopping list travels between two phones through the real Worker', () async {
    final list = hisStore.createNote(isChecklist: true);
    hisStore.put(list.copyWith(title: 'Groceries').upsertItem(
          ChecklistItem.create(text: 'milk', amount: '2', order: 1),
        ));
    expect(await his.sync(), isNot(contains('unreachable')));

    await hers.sync();

    final onHers = herStore.notes.single;
    expect(onHers.title, 'Groceries');
    expect(onHers.liveItems.single.text, 'milk');
    expect(onHers.liveItems.single.amount, '2');
  });

  test('crossing an item off reaches the other phone via the relay', () async {
    final list = hisStore.createNote(isChecklist: true);
    hisStore.put(list.copyWith(title: 'Groceries').upsertItem(
          ChecklistItem.create(text: 'milk', order: 1),
        ));
    await his.sync();
    await hers.sync();

    final herCopy = herStore.notes.single;
    herStore.put(herCopy.upsertItem(herCopy.liveItems.single.copyWith(done: true)));
    await hers.sync();

    await his.sync();
    expect(hisStore.notes.single.liveItems.single.done, isTrue);
  });

  test('the real Worker rejects a wrong secret', () async {
    hisStore.put(hisStore.createNote().copyWith(title: 'Private'));
    await his.sync();

    final intruderStore = await freshStore('intruder');
    addTearDown(intruderStore.dispose);
    final intruder = CloudSync(
      store: intruderStore,
      pairing: Pairing(
        deviceId: 'dev9',
        padId: pad.padId,
        secret: 'definitely-the-wrong-secret',
        relayUrl: relayUrl,
      ),
    );

    await intruder.sync();
    expect(intruderStore.notes, isEmpty);
  });

  test('idle polling against the real Worker is stable', () async {
    hisStore.put(hisStore.createNote().copyWith(title: 'Stable'));
    await his.sync();
    await hers.sync();
    final snapshot = herStore.exportJson();

    await hers.sync();
    await hers.sync();

    expect(herStore.exportJson(), snapshot);
  });
}
