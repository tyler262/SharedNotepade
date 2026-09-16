import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/note.dart';
import 'app_paths.dart';

/// Every note lives in one JSON file on this phone. That file is the source
/// of truth — there is no server and nothing to sign into.
///
/// Writes go to a temp file and are then renamed over the real one, so a crash
/// mid-save can never leave a half-written file. The previous good copy is
/// kept alongside as a backup.
class NoteStore extends ChangeNotifier {
  final Map<String, Note> _notes = {};

  /// Fired after any local edit, so sync can push promptly.
  VoidCallback? onLocalChange;

  static const _tombstoneTtl = Duration(days: 30);

  Directory? _dir;
  Timer? _saveDebounce;

  Future<Directory> _directory() async => _dir ??= await AppPaths.dir();

  Future<File> _mainFile() async => File('${(await _directory()).path}/notes.json');
  Future<File> _tmpFile() async => File('${(await _directory()).path}/notes.json.tmp');
  Future<File> _backupFile() async => File('${(await _directory()).path}/notes.backup.json');

  List<Note> get notes {
    final live = _notes.values.where((n) => !n.deleted).toList()
      ..sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
    return live;
  }

  /// Includes tombstones — sync needs them so a delete propagates.
  List<Note> get allForSync => _notes.values.toList();

  Note? byId(String id) => _notes[id];

  Future<void> load() async {
    for (final file in [await _mainFile(), await _tmpFile(), await _backupFile()]) {
      if (!await file.exists()) continue;
      try {
        final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final list = (decoded['notes'] as List)
            .map((e) => Note.fromJson(e as Map<String, dynamic>))
            .toList();
        _notes
          ..clear()
          ..addEntries(list.map((n) => MapEntry(n.id, n)));
        _purgeTombstones();
        notifyListeners();
        return;
      } catch (_) {
        // Try the next candidate rather than starting empty.
        continue;
      }
    }
  }

  void _purgeTombstones() {
    final cutoff = nowMs() - _tombstoneTtl.inMilliseconds;
    _notes.removeWhere((_, n) => n.deleted && n.updatedAt < cutoff);
    for (final entry in _notes.entries.toList()) {
      final kept = entry.value.items.where((i) => !(i.deleted && i.updatedAt < cutoff)).toList();
      if (kept.length != entry.value.items.length) {
        _notes[entry.key] = entry.value.withItems(kept);
      }
    }
  }

  Future<void> _writeNow() async {
    final payload = jsonEncode({
      'version': 1,
      'notes': _notes.values.map((n) => n.toJson()).toList(),
    });
    final tmp = await _tmpFile();
    final main = await _mainFile();
    await tmp.writeAsString(payload, flush: true);
    if (await main.exists()) {
      try {
        await main.copy((await _backupFile()).path);
      } catch (_) {
        // A missing backup is not worth failing the save over.
      }
    }
    await tmp.rename(main.path);
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(_writeNow());
    });
  }

  /// Flushes any pending write immediately (used when the app goes to background).
  Future<void> flush() async {
    _saveDebounce?.cancel();
    await _writeNow();
  }

  void _commit({bool local = true}) {
    _scheduleSave();
    notifyListeners();
    if (local) onLocalChange?.call();
  }

  void put(Note note) {
    _notes[note.id] = note;
    _commit();
  }

  Note createNote({bool isChecklist = false}) {
    final note = Note.create(isChecklist: isChecklist);
    _notes[note.id] = note;
    _commit();
    return note;
  }

  void deleteNote(String id) {
    final n = _notes[id];
    if (n == null) return;
    _notes[id] = n.copyWith(deleted: true);
    _commit();
  }

  /// Folds another phone's notes into ours. Returns true if anything changed.
  bool mergeRemote(List<Note> incoming) {
    var changed = false;
    for (final remote in incoming) {
      final local = _notes[remote.id];
      if (local == null) {
        _notes[remote.id] = remote;
        changed = true;
        continue;
      }
      final merged = Note.merge(local, remote);
      if (jsonEncode(merged.toJson()) != jsonEncode(local.toJson())) {
        _notes[remote.id] = merged;
        changed = true;
      }
    }
    if (changed) {
      _purgeTombstones();
      // Not a local change: merging shouldn't trigger another outbound push.
      _commit(local: false);
    }
    return changed;
  }

  String exportJson() => jsonEncode({
        'version': 1,
        'notes': _notes.values.map((n) => n.toJson()).toList(),
      });

  /// Merges a pasted/shared export. Returns null on success, else an error message.
  String? importJson(String raw) {
    try {
      final decoded = jsonDecode(raw.trim()) as Map<String, dynamic>;
      final list = (decoded['notes'] as List)
          .map((e) => Note.fromJson(e as Map<String, dynamic>))
          .toList();
      mergeRemote(list);
      return null;
    } catch (_) {
      return "That doesn't look like a Shared Notepad backup.";
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}
