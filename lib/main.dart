import 'package:flutter/material.dart';

import 'data/note_store.dart';
import 'data/pairing.dart';
import 'sync/sync_coordinator.dart';
import 'ui/notes_page.dart';
import 'ui/pairing_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = NoteStore();
  await store.load();

  final pairing = await Pairing.load();
  final sync = SyncCoordinator(store: store, pairing: pairing);
  store.onLocalChange = sync.schedulePush;
  await sync.start();

  runApp(SharedNotepadApp(store: store, sync: sync));
}

class SharedNotepadApp extends StatefulWidget {
  final NoteStore store;
  final SyncCoordinator sync;

  const SharedNotepadApp({super.key, required this.store, required this.sync});

  @override
  State<SharedNotepadApp> createState() => _SharedNotepadAppState();
}

class _SharedNotepadAppState extends State<SharedNotepadApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.sync.syncNow();
    } else if (state == AppLifecycleState.paused) {
      // Make sure nothing is left sitting in the save debounce.
      widget.store.flush();
    }
  }

  @override
  Widget build(BuildContext context) {
    final seed = const Color(0xFF3F6E4B);
    return MaterialApp(
      title: 'Shared Notepad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed), useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: widget.sync.pairing.isPaired
          ? NotesPage(store: widget.store, sync: widget.sync)
          : _FirstRunGate(store: widget.store, sync: widget.sync),
    );
  }
}

/// Shown until this phone has either started a notepad or joined one.
class _FirstRunGate extends StatefulWidget {
  final NoteStore store;
  final SyncCoordinator sync;

  const _FirstRunGate({required this.store, required this.sync});

  @override
  State<_FirstRunGate> createState() => _FirstRunGateState();
}

class _FirstRunGateState extends State<_FirstRunGate> {
  @override
  Widget build(BuildContext context) {
    if (widget.sync.pairing.isPaired) {
      return NotesPage(store: widget.store, sync: widget.sync);
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.edit_note, size: 72),
                const SizedBox(height: 16),
                Text('Shared Notepad', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                Text(
                  'Notes and shopping lists kept on both your phones. '
                  'They sync to each other over your home Wi-Fi — no account, '
                  'no server, nothing stored online.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => PairingPage(store: widget.store, sync: widget.sync),
                    ));
                    if (mounted) setState(() {});
                  },
                  child: const Text('Set up'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
