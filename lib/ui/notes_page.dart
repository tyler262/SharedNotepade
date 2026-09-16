import 'package:flutter/material.dart';

import '../data/note_store.dart';
import '../models/note.dart';
import '../sync/sync_coordinator.dart';
import '../sync/sync_service.dart' show SyncStatus;
import 'note_editor_page.dart';
import 'pairing_page.dart';

class NotesPage extends StatelessWidget {
  final NoteStore store;
  final SyncCoordinator sync;

  const NotesPage({super.key, required this.store, required this.sync});

  void _open(BuildContext context, Note note) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NoteEditorPage(store: store, noteId: note.id),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared Notepad'),
        actions: [
          IconButton(
            tooltip: 'Sync now',
            icon: const Icon(Icons.sync),
            onPressed: () => sync.syncNow(),
          ),
          IconButton(
            tooltip: 'Pairing & backup',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PairingPage(store: store, sync: sync),
            )),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: ValueListenableBuilder<SyncStatus>(
            valueListenable: sync.status,
            builder: (context, s, _) => Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 6),
              child: Row(
                children: [
                  if (s.busy)
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      s.lastSyncedAt == null ? Icons.cloud_off_outlined : Icons.check_circle_outline,
                      size: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      s.message,
                      style: Theme.of(context).textTheme.labelSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'list',
            tooltip: 'New shopping list',
            onPressed: () => _open(context, store.createNote(isChecklist: true)),
            child: const Icon(Icons.checklist),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'note',
            tooltip: 'New note',
            onPressed: () => _open(context, store.createNote()),
            child: const Icon(Icons.add),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: store,
        builder: (context, _) {
          final notes = store.notes;
          if (notes.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 160),
            itemCount: notes.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final note = notes[i];
              return Dismissible(
                key: ValueKey(note.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Theme.of(context).colorScheme.errorContainer,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Icon(Icons.delete_outline),
                ),
                onDismissed: (_) {
                  store.deleteNote(note.id);
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(
                      content: Text('Deleted "${_titleOf(note)}"'),
                      action: SnackBarAction(
                        label: 'Undo',
                        onPressed: () {
                          final n = store.byId(note.id);
                          if (n != null) store.put(n.copyWith(deleted: false));
                        },
                      ),
                    ));
                },
                child: ListTile(
                  leading: Icon(note.isChecklist ? Icons.checklist : Icons.notes),
                  title: Text(
                    _titleOf(note),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _subtitleOf(note),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _open(context, note),
                ),
              );
            },
          );
        },
      ),
    );
  }

  static String _titleOf(Note n) {
    if (n.title.trim().isNotEmpty) return n.title.trim();
    if (n.isChecklist && n.liveItems.isNotEmpty) return n.liveItems.first.text;
    final firstLine = n.body.trim().split('\n').first;
    return firstLine.isEmpty ? 'Untitled' : firstLine;
  }

  static String _subtitleOf(Note n) {
    if (n.isChecklist) {
      final total = n.liveItems.length;
      if (total == 0) return 'Empty list';
      final remaining = total - n.doneCount;
      return remaining == 0
          ? 'All $total done'
          : '$remaining of $total left · ${n.liveItems.where((i) => !i.done).take(3).map((i) => i.text).join(", ")}';
    }
    final body = n.body.trim();
    return body.isEmpty ? 'Empty note' : body;
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.edit_note, size: 56),
            const SizedBox(height: 12),
            Text(
              'Nothing here yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap + for a note, or the checklist button for a shopping list.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
