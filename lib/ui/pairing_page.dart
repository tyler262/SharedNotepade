import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../data/note_store.dart';
import '../data/pairing.dart';
import '../sync/cloud_sync.dart';
import '../sync/sync_coordinator.dart';
import '../sync/sync_service.dart' show SyncStatus;

class PairingPage extends StatefulWidget {
  final NoteStore store;
  final SyncCoordinator sync;

  const PairingPage({super.key, required this.store, required this.sync});

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  bool _checkingRelay = false;

  Pairing get _pairing => widget.sync.pairing;

  Future<void> _apply(Pairing next) async {
    await next.save();
    await widget.sync.restartWith(next);
    if (mounted) setState(() {});
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _joinDialog() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join a notepad'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: 'Paste the pairing code your partner sent',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) return;
    final parsed = Pairing.decodePairCode(code);
    if (parsed == null) {
      _toast("That code didn't look right. Copy the whole thing and try again.");
      return;
    }
    await _apply(_pairing.joinPad(
      parsed.padId,
      parsed.secret,
      newRelayUrl: parsed.relayUrl.isNotEmpty ? parsed.relayUrl : null,
    ));
    _toast(parsed.relayUrl.isNotEmpty
        ? 'Paired. You can sync from anywhere.'
        : 'Paired. Sync happens when both phones are on the same Wi-Fi.');
  }

  Future<void> _relayDialog() async {
    final controller = TextEditingController(text: _pairing.relayUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sync from anywhere'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste the address of the relay you deployed to Cloudflare. '
              'See the README for the one-time setup.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'shared-notepad-relay.you.workers.dev',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          if (_pairing.hasRelay)
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Turn off'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (url == null) return;

    if (url.trim().isEmpty) {
      await _apply(_pairing.withRelayUrl(''));
      _toast('Relay turned off. Back to Wi-Fi-only syncing.');
      return;
    }

    setState(() => _checkingRelay = true);
    final reachable = await CloudSync.probe(url);
    if (!mounted) return;
    setState(() => _checkingRelay = false);

    if (!reachable) {
      _toast("Couldn't reach that address. Check it and try again.");
      return;
    }
    await _apply(_pairing.withRelayUrl(url));
    _toast('Relay connected. Your notes now sync from anywhere.');
  }

  Future<void> _importDialog() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from backup'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(hintText: 'Paste the backup text here'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (raw == null || raw.trim().isEmpty) return;
    final err = widget.store.importJson(raw);
    _toast(err ?? 'Backup merged into your notes.');
  }

  Future<void> _unpairDialog() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave this notepad?'),
        content: const Text(
          'Your notes stay on this phone, but it will stop syncing with your '
          'partner until you pair again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true) return;
    await _apply(_pairing.unpair());
  }

  @override
  Widget build(BuildContext context) {
    final paired = _pairing.isPaired;
    return Scaffold(
      appBar: AppBar(title: const Text('Pairing & backup')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (!paired) ...[
            const _Section('Get started'),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('Start a new notepad'),
              subtitle: const Text('Then send the pairing code to your partner'),
              onTap: () async {
                await _apply(_pairing.createPad());
                _toast('Notepad created. Send the pairing code to your partner.');
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Join with a code'),
              subtitle: const Text('Paste the code from your partner\'s phone'),
              onTap: _joinDialog,
            ),
          ] else ...[
            const _Section('Pairing code'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Send this to your partner once. Anyone with it can read and '
                'edit this notepad, so send it in a private message.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                _pairing.pairCode,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _pairing.pairCode));
                      _toast('Pairing code copied');
                    },
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Send'),
                    onPressed: () => SharePlus.instance.share(
                      ShareParams(
                        text: _pairing.pairCode,
                        subject: 'Shared Notepad pairing code',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 32),
            const _Section('Sync'),
            ValueListenableBuilder<SyncStatus>(
              valueListenable: widget.sync.status,
              builder: (context, s, _) => ListTile(
                leading: const Icon(Icons.wifi_tethering),
                title: Text(s.message),
                subtitle: Text(
                  s.lastSyncedAt == null
                      ? (_pairing.hasRelay
                          ? 'Syncs over Wi-Fi at home, or anywhere via the relay'
                          : 'Both phones need to be on the same Wi-Fi')
                      : 'Last synced ${_ago(s.lastSyncedAt!)}',
                ),
                trailing: TextButton(
                  onPressed: () => widget.sync.syncNow(),
                  child: const Text('Sync now'),
                ),
              ),
            ),
            ListTile(
              leading: _checkingRelay
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(_pairing.hasRelay ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
              title: Text(_pairing.hasRelay ? 'Syncing from anywhere' : 'Sync from anywhere'),
              subtitle: Text(
                _pairing.hasRelay
                    ? _pairing.relayUrl
                    : 'Off — add your Cloudflare relay to sync away from home',
              ),
              onTap: _checkingRelay ? null : _relayDialog,
            ),
          ],
          const Divider(height: 32),
          const _Section('Backup'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Your notes live on this phone. Sending yourself a backup now and '
              'then means you can restore them on any phone, even a new one.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Send a backup'),
            subtitle: const Text('Email or message the whole notepad to yourself'),
            onTap: () => SharePlus.instance.share(
              ShareParams(
                text: widget.store.exportJson(),
                subject: 'Shared Notepad backup',
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Restore from backup'),
            subtitle: const Text('Merges a backup into what is already here'),
            onTap: _importDialog,
          ),
          if (paired) ...[
            const Divider(height: 32),
            ListTile(
              leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
              title: Text(
                'Leave this notepad',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: _unpairDialog,
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}

class _Section extends StatelessWidget {
  final String label;

  const _Section(this.label);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          label.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 1.1,
              ),
        ),
      );
}
