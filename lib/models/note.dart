import 'dart:convert';
import 'dart:math';

final _rnd = Random.secure();

/// Random hex id. 8 bytes is plenty for a two-phone notepad.
String newId([int bytes = 8]) => List<int>.generate(bytes, (_) => _rnd.nextInt(256))
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

int nowMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

/// One line of a shopping list: "2 lbs" + "chicken thighs", tickable.
class ChecklistItem {
  final String id;
  final String text;

  /// Free text rather than a number, so "2", "1 gallon" and "a bunch" all work.
  final String amount;
  final bool done;
  final bool deleted;

  /// Sort key. Fractional, so an item can always be inserted between two
  /// others without renumbering the rest (which would fight with merging).
  final double order;

  /// Last local edit, in epoch ms. Drives last-write-wins merging.
  final int updatedAt;

  const ChecklistItem({
    required this.id,
    required this.order,
    required this.updatedAt,
    this.text = '',
    this.amount = '',
    this.done = false,
    this.deleted = false,
  });

  factory ChecklistItem.create({String text = '', String amount = '', required double order}) =>
      ChecklistItem(id: newId(), text: text, amount: amount, order: order, updatedAt: nowMs());

  ChecklistItem copyWith({
    String? text,
    String? amount,
    bool? done,
    bool? deleted,
    double? order,
  }) =>
      ChecklistItem(
        id: id,
        text: text ?? this.text,
        amount: amount ?? this.amount,
        done: done ?? this.done,
        deleted: deleted ?? this.deleted,
        order: order ?? this.order,
        updatedAt: nowMs(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'amount': amount,
        'done': done,
        'deleted': deleted,
        'order': order,
        'updatedAt': updatedAt,
      };

  factory ChecklistItem.fromJson(Map<String, dynamic> j) => ChecklistItem(
        id: j['id'] as String,
        text: (j['text'] ?? '') as String,
        amount: (j['amount'] ?? '') as String,
        done: (j['done'] ?? false) as bool,
        deleted: (j['deleted'] ?? false) as bool,
        order: ((j['order'] ?? 0) as num).toDouble(),
        updatedAt: (j['updatedAt'] ?? 0) as int,
      );

  /// Last write wins, with a content tiebreak so both phones pick the same
  /// winner when two edits share a millisecond.
  static ChecklistItem pick(ChecklistItem a, ChecklistItem b) {
    if (a.updatedAt != b.updatedAt) return a.updatedAt > b.updatedAt ? a : b;
    return jsonEncode(a.toJson()).compareTo(jsonEncode(b.toJson())) >= 0 ? a : b;
  }
}

/// A note. Either free text (`body`) or a tickable list (`items`).
class Note {
  final String id;
  final String title;
  final String body;
  final bool isChecklist;
  final bool deleted;

  /// Covers the scalar fields above ONLY — never bumped when an item changes,
  /// so ticking something off on one phone can't clobber a title edit on the other.
  final int updatedAt;

  final List<ChecklistItem> items;

  const Note({
    required this.id,
    required this.updatedAt,
    this.title = '',
    this.body = '',
    this.isChecklist = false,
    this.deleted = false,
    this.items = const [],
  });

  factory Note.create({String title = '', bool isChecklist = false}) =>
      Note(id: newId(), title: title, isChecklist: isChecklist, updatedAt: nowMs());

  /// Most recent change anywhere in the note. Used for sorting and "edited" labels.
  int get lastActivity =>
      items.fold(updatedAt, (m, i) => i.updatedAt > m ? i.updatedAt : m);

  List<ChecklistItem> get liveItems {
    final live = items.where((i) => !i.deleted).toList()
      ..sort((a, b) {
        final c = a.order.compareTo(b.order);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    return live;
  }

  int get doneCount => liveItems.where((i) => i.done).length;

  double get nextOrder =>
      items.isEmpty ? 1.0 : items.map((i) => i.order).reduce(max) + 1.0;

  /// Changes a scalar field. Bumps [updatedAt].
  Note copyWith({String? title, String? body, bool? isChecklist, bool? deleted}) => Note(
        id: id,
        title: title ?? this.title,
        body: body ?? this.body,
        isChecklist: isChecklist ?? this.isChecklist,
        deleted: deleted ?? this.deleted,
        updatedAt: nowMs(),
        items: items,
      );

  /// Changes the item list only. Deliberately leaves [updatedAt] alone.
  Note withItems(List<ChecklistItem> newItems) => Note(
        id: id,
        title: title,
        body: body,
        isChecklist: isChecklist,
        deleted: deleted,
        updatedAt: updatedAt,
        items: newItems,
      );

  Note upsertItem(ChecklistItem item) {
    final next = List<ChecklistItem>.from(items);
    final idx = next.indexWhere((i) => i.id == item.id);
    if (idx >= 0) {
      next[idx] = item;
    } else {
      next.add(item);
    }
    return withItems(next);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'isChecklist': isChecklist,
        'deleted': deleted,
        'updatedAt': updatedAt,
        'items': items.map((i) => i.toJson()).toList(),
      };

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        id: j['id'] as String,
        title: (j['title'] ?? '') as String,
        body: (j['body'] ?? '') as String,
        isChecklist: (j['isChecklist'] ?? false) as bool,
        deleted: (j['deleted'] ?? false) as bool,
        updatedAt: (j['updatedAt'] ?? 0) as int,
        items: ((j['items'] ?? const []) as List)
            .map((e) => ChecklistItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  String _scalarKey() => jsonEncode({
        'title': title,
        'body': body,
        'isChecklist': isChecklist,
        'deleted': deleted,
      });

  /// Merges two versions of the same note from two phones.
  ///
  /// Scalars and items are resolved independently, so "he renamed the note"
  /// and "she ticked off milk" both survive a merge instead of one winning.
  static Note merge(Note a, Note b) {
    assert(a.id == b.id);
    final Note scalars;
    if (a.updatedAt != b.updatedAt) {
      scalars = a.updatedAt > b.updatedAt ? a : b;
    } else {
      scalars = a._scalarKey().compareTo(b._scalarKey()) >= 0 ? a : b;
    }

    final byId = <String, ChecklistItem>{};
    for (final i in a.items) {
      byId[i.id] = i;
    }
    for (final i in b.items) {
      final existing = byId[i.id];
      byId[i.id] = existing == null ? i : ChecklistItem.pick(existing, i);
    }

    return Note(
      id: a.id,
      title: scalars.title,
      body: scalars.body,
      isChecklist: scalars.isChecklist,
      deleted: scalars.deleted,
      updatedAt: scalars.updatedAt,
      items: byId.values.toList(),
    );
  }
}
