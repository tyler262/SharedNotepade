import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where the notepad's files live.
///
/// Indirected through here so tests can point the app at a temp directory
/// instead of the real app-documents folder.
class AppPaths {
  static Future<Directory> Function()? _resolver;

  static void overrideForTests(Directory dir) => _resolver = () async => dir;

  static Future<Directory> dir() async =>
      _resolver == null ? getApplicationDocumentsDirectory() : _resolver!();
}
