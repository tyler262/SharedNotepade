import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_notepad/data/app_paths.dart';
import 'package:shared_notepad/data/note_store.dart';
import 'package:shared_notepad/models/note.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('snp_store');
    AppPaths.overrideForTests(dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<NoteStore> reopen() async {
    final s = NoteStore();
    await s.load();
    return s;
  }

  test('notes survive closing and reopening the app', () async {
    final store = NoteStore();
    await store.load();
    final list = store.createNote(isChecklist: true);
    store.put(list.copyWith(title: 'Groceries').upsertItem(
          ChecklistItem.create(text: 'eggs', amount: '1 dozen', order: 1),
        ));
    await store.flush();

    final reopened = await reopen();
    final n = reopened.notes.single;
    expect(n.title, 'Groceries');
    expect(n.liveItems.single.text, 'eggs');
    expect(n.liveItems.single.amount, '1 dozen');
  });

  test('a corrupted main file falls back to the backup instead of losing everything', () async {
    final store = NoteStore();
    await store.load();
    store.put(store.createNote().copyWith(title: 'First save'));
    await store.flush();

    // Second save rotates the first one into the backup slot.
    store.put(store.createNote().copyWith(title: 'Second save'));
    await store.flush();

    expect(File('${dir.path}/notes.backup.json').existsSync(), isTrue);
    await File('${dir.path}/notes.json').writeAsString('{ truncated garba');

    final recovered = await reopen();
    expect(recovered.notes.map((n) => n.title), contains('First save'));
  });

  test('an empty data directory opens cleanly rather than erroring', () async {
    final store = await reopen();
    expect(store.notes, isEmpty);
  });

  test('a deleted note stays as a tombstone so the delete can propagate', () async {
    final store = NoteStore();
    await store.load();
    final n = store.createNote();
    store.put(n.copyWith(title: 'Bye'));
    store.deleteNote(n.id);
    await store.flush();

    expect(store.notes, isEmpty, reason: 'hidden from the user');
    expect(store.allForSync.where((x) => x.id == n.id), hasLength(1),
        reason: 'still sent to the other phone');
  });

  test('exporting and re-importing a backup restores the notes', () async {
    final store = NoteStore();
    await store.load();
    store.put(store.createNote().copyWith(title: 'Keep me'));
    final backup = store.exportJson();

    final fresh = await reopen();
    fresh.importJson(backup);

    expect(fresh.notes.single.title, 'Keep me');
  });

  test('importing nonsense reports an error and changes nothing', () async {
    final store = await reopen();
    store.put(store.createNote().copyWith(title: 'Mine'));

    expect(store.importJson('hello world'), isNotNull);
    expect(store.notes.single.title, 'Mine');
  });

  test('a local edit notifies sync, a merge from the partner does not', () async {
    final store = await reopen();
    var pushes = 0;
    store.onLocalChange = () => pushes++;

    store.put(store.createNote().copyWith(title: 'Typed here'));
    final afterLocal = pushes;

    store.mergeRemote([Note.create(title: 'From partner')]);

    expect(afterLocal, greaterThan(0));
    expect(pushes, afterLocal, reason: 'merging must not bounce a push back');
  });
}
