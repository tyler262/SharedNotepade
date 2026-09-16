import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_notepad/models/note.dart';

ChecklistItem item(
  String id, {
  String text = '',
  String amount = '',
  bool done = false,
  bool deleted = false,
  double order = 1,
  required int at,
}) =>
    ChecklistItem(
      id: id,
      text: text,
      amount: amount,
      done: done,
      deleted: deleted,
      order: order,
      updatedAt: at,
    );

Note note(
  String id, {
  String title = '',
  String body = '',
  bool isChecklist = false,
  bool deleted = false,
  List<ChecklistItem> items = const [],
  required int at,
}) =>
    Note(
      id: id,
      title: title,
      body: body,
      isChecklist: isChecklist,
      deleted: deleted,
      items: items,
      updatedAt: at,
    );

void main() {
  group('Note.merge', () {
    test('a title edit and an item tick on two phones both survive', () {
      // He renames the list at t=200; she ticks "milk" off at t=300.
      final his = note(
        'n1',
        title: 'Costco run',
        isChecklist: true,
        at: 200,
        items: [item('i1', text: 'milk', at: 100)],
      );
      final hers = note(
        'n1',
        title: 'Groceries',
        isChecklist: true,
        at: 100,
        items: [item('i1', text: 'milk', done: true, at: 300)],
      );

      final merged = Note.merge(his, hers);

      expect(merged.title, 'Costco run', reason: 'his newer title wins');
      expect(merged.liveItems.single.done, isTrue, reason: 'her tick is not clobbered');
    });

    test('ticking an item does not bump the note timestamp', () {
      final n = note('n1', title: 'List', at: 100, items: [item('i1', at: 100)]);
      final ticked = n.upsertItem(n.items.single.copyWith(done: true));

      expect(ticked.updatedAt, 100, reason: 'scalar clock untouched by item edits');
      expect(ticked.lastActivity, greaterThan(100));
    });

    test('items added on both phones are both kept', () {
      final his = note('n1', at: 100, items: [item('i1', text: 'bread', at: 110)]);
      final hers = note('n1', at: 100, items: [item('i2', text: 'eggs', at: 120)]);

      final merged = Note.merge(his, hers);

      expect(merged.liveItems.map((i) => i.text), containsAll(['bread', 'eggs']));
    });

    test('a delete beats an older edit, and a newer edit undoes a delete', () {
      final deletedLater = Note.merge(
        note('n1', title: 'keep', at: 100),
        note('n1', deleted: true, at: 200),
      );
      expect(deletedLater.deleted, isTrue);

      final revived = Note.merge(
        note('n1', deleted: true, at: 200),
        note('n1', title: 'back', at: 300),
      );
      expect(revived.deleted, isFalse);
      expect(revived.title, 'back');
    });

    test('removing an item on one phone removes it after merging', () {
      final his = note('n1', at: 100, items: [item('i1', text: 'milk', at: 100)]);
      final hers = note('n1', at: 100, items: [item('i1', text: 'milk', deleted: true, at: 200)]);

      expect(Note.merge(his, hers).liveItems, isEmpty);
    });

    test('merge is order-independent, so both phones reach the same state', () {
      final a = note(
        'n1',
        title: 'A',
        at: 300,
        items: [item('i1', text: 'x', at: 100), item('i2', text: 'y', at: 400)],
      );
      final b = note(
        'n1',
        title: 'B',
        at: 200,
        items: [item('i1', text: 'x!', at: 500), item('i3', text: 'z', at: 150)],
      );

      String shape(Note n) => jsonEncode({
            'title': n.title,
            'items': (n.items.toList()..sort((p, q) => p.id.compareTo(q.id)))
                .map((i) => i.toJson())
                .toList(),
          });

      expect(shape(Note.merge(a, b)), shape(Note.merge(b, a)));
    });

    test('merging the same note twice changes nothing further', () {
      final a = note('n1', title: 'A', at: 300, items: [item('i1', text: 'x', at: 100)]);
      final b = note('n1', title: 'B', at: 200, items: [item('i1', text: 'y', at: 500)]);

      final once = Note.merge(a, b);
      final twice = Note.merge(once, b);

      expect(jsonEncode(twice.toJson()), jsonEncode(once.toJson()));
    });

    test('same-millisecond edits resolve to the same winner on both phones', () {
      final a = note('n1', title: 'Apples', at: 100);
      final b = note('n1', title: 'Bananas', at: 100);

      expect(Note.merge(a, b).title, Note.merge(b, a).title);
    });
  });

  group('ordering', () {
    test('items sort by their fractional order, not insertion order', () {
      final n = note('n1', at: 1, items: [
        item('i1', text: 'third', order: 3, at: 1),
        item('i2', text: 'first', order: 1, at: 1),
        item('i3', text: 'second', order: 2, at: 1),
      ]);

      expect(n.liveItems.map((i) => i.text), ['first', 'second', 'third']);
    });

    test('an item can always be slotted between two neighbours', () {
      final n = note('n1', at: 1, items: [
        item('i1', order: 1, at: 1),
        item('i2', order: 2, at: 1),
      ]);
      final moved = n.upsertItem(n.items.last.copyWith(order: 0.5));

      expect(moved.liveItems.first.id, 'i2');
    });
  });
}
