import 'dart:convert';
import 'dart:io';

import '../models/note.dart';
import 'app_paths.dart';

/// Identity for this device and the notepad it shares.
///
/// There is no account and no server: a "pad" is just a shared id plus a
/// shared secret that two phones both hold. Whoever has the secret can sync.
class Pairing {
  final String deviceId;
  final String padId;
  final String secret;

  /// Base URL of the Cloudflare relay, or empty for Wi-Fi-only syncing.
  /// Travels inside the pairing code, so only the phone that deployed the
  /// relay ever has to type it.
  final String relayUrl;

  const Pairing({
    required this.deviceId,
    required this.padId,
    required this.secret,
    this.relayUrl = '',
  });

  bool get isPaired => padId.isNotEmpty && secret.isNotEmpty;

  bool get hasRelay => relayUrl.isNotEmpty;

  /// The string you text to your partner. Carries the pad, its secret and the
  /// relay address.
  String get pairCode {
    final raw = utf8.encode(jsonEncode({
      'p': padId,
      's': secret,
      if (relayUrl.isNotEmpty) 'r': relayUrl,
    }));
    return base64Url.encode(raw).replaceAll('=', '');
  }

  static ({String padId, String secret, String relayUrl})? decodePairCode(String code) {
    try {
      var c = code.trim().replaceAll(RegExp(r'\s'), '');
      c = c.padRight((c.length + 3) ~/ 4 * 4, '=');
      final j = jsonDecode(utf8.decode(base64Url.decode(c))) as Map<String, dynamic>;
      final padId = j['p'] as String?;
      final secret = j['s'] as String?;
      if (padId == null || secret == null || padId.isEmpty || secret.isEmpty) return null;
      return (padId: padId, secret: secret, relayUrl: (j['r'] ?? '') as String);
    } catch (_) {
      return null;
    }
  }

  /// Trims a pasted relay URL into the form the client expects.
  static String normalizeRelayUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';
    if (!url.startsWith('http://') && !url.startsWith('https://')) url = 'https://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Map<String, dynamic> toJson() =>
      {'deviceId': deviceId, 'padId': padId, 'secret': secret, 'relayUrl': relayUrl};

  factory Pairing.fromJson(Map<String, dynamic> j) => Pairing(
        deviceId: j['deviceId'] as String,
        padId: (j['padId'] ?? '') as String,
        secret: (j['secret'] ?? '') as String,
        relayUrl: (j['relayUrl'] ?? '') as String,
      );

  static Future<File> _file() async {
    final dir = await AppPaths.dir();
    return File('${dir.path}/pad.json');
  }

  static Future<Pairing> load() async {
    final f = await _file();
    if (await f.exists()) {
      try {
        return Pairing.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      } catch (_) {
        // Fall through and mint a fresh identity rather than bricking the app.
      }
    }
    final fresh = Pairing(deviceId: newId(4), padId: '', secret: '');
    await fresh.save();
    return fresh;
  }

  Future<void> save() async {
    final f = await _file();
    await f.writeAsString(jsonEncode(toJson()), flush: true);
  }

  /// Starts a brand-new pad on this phone, keeping any relay already set up.
  Pairing createPad() =>
      Pairing(deviceId: deviceId, padId: newId(8), secret: newId(24), relayUrl: relayUrl);

  Pairing joinPad(String newPadId, String newSecret, {String? newRelayUrl}) => Pairing(
        deviceId: deviceId,
        padId: newPadId,
        secret: newSecret,
        relayUrl: newRelayUrl ?? relayUrl,
      );

  Pairing withRelayUrl(String url) => Pairing(
        deviceId: deviceId,
        padId: padId,
        secret: secret,
        relayUrl: normalizeRelayUrl(url),
      );

  /// Leaves the pad but keeps the relay address, so re-pairing is one step.
  Pairing unpair() => Pairing(deviceId: deviceId, padId: '', secret: '', relayUrl: relayUrl);
}
