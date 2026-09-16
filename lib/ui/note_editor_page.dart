import 'dart:async';

import 'package:flutter/material.dart';

import '../data/note_store.dart';
import '../models/note.dart';

class NoteEditorPage extends StatefulWidget {
  final NoteStore store;
  final String noteId;

  const NoteEditorPage({super.key, required this.store, required this.noteId});

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _titleFocus = FocusNode();
  final _bodyFocus = FocusNode();

  final _newItem = TextEditingController();
  final _newItemFocus = FocusNode();

  final Map<String, TextEditingController> _itemText = {};
  final Map<String, TextEditingController> _itemAmount = {};
  final Map<String, FocusNode> _itemFocus = {};
  final Map<String, FocusNode> _itemAmountFocus = {};
  final Map<String, Timer> _debounce = {};

  Note? get _note => widget.store.byId(widget.noteId);

  @override
  void initState() {
    super.initState();
    final n = _note;
    if (n != null) {
      _title.text = n.title;
      _body.text = n.body;
    }
    _title.addListener(() => _debouncedScalar('title', () {
          final cur = _note;
          if (cur != null && cur.title != _title.text) {
            widget.store.put(cur.copyWith(title: _title.text));
          }
        }));
    _body.addListener(() => _debouncedScalar('body', () {
          final cur = _note;
          if (cur != null && cur.body != _body.text) {
            widget.store.put(cur.copyWith(body: _body.text));
          }
        }));
  }

  void _debouncedScalar(String key, VoidCallback action) {
    _debounce[key]?.cancel();
    _debounce[key] = Timer(const Duration(milliseconds: 500), action);
  }

  @override
  void dispose() {
    for (final t in _debounce.values) {
      t.cancel();
    }
    // Flush anything still sitting in the debounce window.
    final cur = _note;
    if (cur != null) {
      var updated = cur;
      var dirty = false;
      if (updated.title != _title.text) {
        updated = updated.copyWith(title: _title.text);
        dirty = true;
      }
      if (!updated.isChecklist && updated.body != _body.text) {
        updated = updated.copyWith(body: _body.text);
        dirty = true;
      }
      if (dirty) widget.store.put(updated);
    }
    _title.dispose();
    _body.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    _newItem.dispose();
    _newItemFocus.dispose();
    for (final c in _itemText.values) {
      c.dispose();
    }
    for (final c in _itemAmount.values) {
      c.dispose();
    }
    for (final f in _itemFocus.values) {
      f.dispose();
    }
    for (final f in _itemAmountFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  /// Keeps a field in step with remote edits without yanking the cursor out
  /// from under whoever is typing in it.
  void _syncController(TextEditingController c, FocusNode f, String remote) {
    if (!f.hasFocus && c.text != remote) {
      c.value = TextEditingValue(text: remote, selection: TextSelection.collapsed(offset: remote.length));
    }
  }

  void _addItem(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final n = _note;
    if (n == null) return;
    widget.store.put(n.upsertItem(ChecklistItem.create(text: trimmed, order: n.nextOrder)));
    _newItem.clear();
    _newItemFocus.requestFocus();
  }

  void _updateItem(ChecklistItem item) {
    final n = _note;
    if (n == null) return;
    widget.store.put(n.upsertItem(item));
  }

  void _toggleChecklist(bool toChecklist) {
    final n = _note;
    if (n == null) return;
    if (toChecklist) {
      final lines = _body.text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      var order = n.nextOrder;
      final items = <ChecklistItem>[...n.items];
      for (final line in lines) {
        items.add(ChecklistItem.create(text: line, order: order));
        order += 1.0;
      }
      widget.store.put(n.copyWith(isChecklist: true, body: '').withItems(items));
      _body.clear();
    } else {
      final text = n.liveItems
          .map((i) => i.amount.isEmpty ? i.text : '${i.amount} ${i.text}')
          .join('\n');
      final merged = _body.text.trim().isEmpty ? text : '${_body.text.trim()}\n$text';
      widget.store.put(n.copyWith(isChecklist: false, body: merged));
      _body.text = merged;
    }
  }

  void _clearChecked() {
    final n = _note;
    if (n == null) return;
    var updated = n;
    for (final item in n.liveItems.where((i) => i.done)) {
      updated = updated.upsertItem(item.copyWith(deleted: true));
    }
    widget.store.put(updated);
  }

  /// [newIndex] already accounts for the dragged row being lifted out.
  void _reorder(int oldIndex, int newIndex) {
    final n = _note;
    if (n == null) return;
    final items = n.liveItems;
    if (oldIndex == newIndex) return;

    final moved = items[oldIndex];
    final without = List<ChecklistItem>.from(items)..removeAt(oldIndex);
    if (without.isEmpty) return;

    // Fractional ordering: slot the item between its new neighbours so no
    // other row has to be renumbered (renumbering fights with merging).
    final double before = newIndex == 0 ? without.first.order - 1.0 : without[newIndex - 1].order;
    final double after =
        newIndex >= without.length ? without.last.order + 1.0 : without[newIndex].order;

    _updateItem(moved.copyWith(order: (before + after) / 2.0));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final note = _note;
        if (note == null || note.deleted) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This note was deleted.')),
          );
        }

        _syncController(_title, _titleFocus, note.title);
        if (!note.isChecklist) _syncController(_body, _bodyFocus, note.body);

        return Scaffold(
          appBar: AppBar(
            title: TextField(
              controller: _title,
              focusNode: _titleFocus,
              style: Theme.of(context).textTheme.titleLarge,
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'Title',
              ),
            ),
            actions: [
              IconButton(
                tooltip: note.isChecklist ? 'Turn back into a note' : 'Turn into a shopping list',
                icon: Icon(note.isChecklist ? Icons.notes : Icons.checklist),
                onPressed: () => _toggleChecklist(!note.isChecklist),
              ),
              if (note.isChecklist)
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'clear') _clearChecked();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'clear',
                      enabled: note.doneCount > 0,
                      child: Text('Clear ${note.doneCount} checked'),
                    ),
                  ],
                ),
            ],
          ),
          body: note.isChecklist ? _buildChecklist(note) : _buildBody(),
        );
      },
    );
  }

  Widget _buildBody() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: _body,
        focusNode: _bodyFocus,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        decoration: const InputDecoration(
          border: InputBorder.none,
          hintText: 'Start writing…',
        ),
      ),
    );
  }

  Widget _buildChecklist(Note note) {
    final items = note.liveItems;
    return Column(
      children: [
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('Add your first item below.'))
              : ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: items.length,
                  onReorderItem: _reorder,
                  itemBuilder: (context, i) => _itemRow(items[i]),
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 8,
            top: 8,
            bottom: MediaQuery.of(context).viewInsets.bottom + 8,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newItem,
                  focusNode: _newItemFocus,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Add an item…',
                  ),
                  onSubmitted: _addItem,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => _addItem(_newItem.text),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _itemRow(ChecklistItem item) {
    final textCtrl = _itemText.putIfAbsent(item.id, () => TextEditingController(text: item.text));
    final amountCtrl =
        _itemAmount.putIfAbsent(item.id, () => TextEditingController(text: item.amount));
    final focus = _itemFocus.putIfAbsent(item.id, () => FocusNode());
    final amountFocus = _itemAmountFocus.putIfAbsent(item.id, () => FocusNode());

    _syncController(textCtrl, focus, item.text);
    _syncController(amountCtrl, amountFocus, item.amount);

    final strike = item.done ? TextDecoration.lineThrough : null;
    final dim = item.done ? Theme.of(context).disabledColor : null;

    return Padding(
      key: ValueKey(item.id),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Checkbox(
            value: item.done,
            onChanged: (v) => _updateItem(item.copyWith(done: v ?? false)),
          ),
          SizedBox(
            width: 64,
            child: TextField(
              controller: amountCtrl,
              focusNode: amountFocus,
              textAlign: TextAlign.center,
              style: TextStyle(decoration: strike, color: dim),
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'Qty',
                isDense: true,
              ),
              onChanged: (v) => _debouncedScalar('amt-${item.id}', () {
                final cur = _note?.items.firstWhere((i) => i.id == item.id, orElse: () => item);
                if (cur != null && cur.amount != v) _updateItem(cur.copyWith(amount: v));
              }),
            ),
          ),
          Expanded(
            child: TextField(
              controller: textCtrl,
              focusNode: focus,
              style: TextStyle(decoration: strike, color: dim),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
              ),
              onChanged: (v) => _debouncedScalar('txt-${item.id}', () {
                final cur = _note?.items.firstWhere((i) => i.id == item.id, orElse: () => item);
                if (cur != null && cur.text != v) _updateItem(cur.copyWith(text: v));
              }),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Remove',
            onPressed: () => _updateItem(item.copyWith(deleted: true)),
          ),
        ],
      ),
    );
  }
}
