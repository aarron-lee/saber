import 'dart:typed_data';

import 'package:saf/saf.dart';

/// Thin wrapper around [Saf] that lets [FileManager] address documents by
/// POSIX-style relative path (e.g. `/folder/note.sbn2`) under a SAF tree
/// root URI, instead of by document URI.
///
/// This is used when the user has picked a custom Android storage directory
/// via the Storage Access Framework: [FileManager.documentsDirectory] is
/// then the tree's `content://` URI rather than a real filesystem path, and
/// raw `dart:io` File/Directory operations can't be used on it under scoped
/// storage.
class SafBackend {
  // disable constructor
  new _();

  static final _saf = Saf();

  /// Whether [path] is a SAF tree/document URI rather than a real path.
  static bool isSafPath(String path) => path.startsWith('content://');

  static List<String> _segments(String relativePath) =>
      relativePath.split('/').where((s) => s.isNotEmpty).toList();

  static Future<SafDocumentFile?> _resolve(
    String rootUri,
    String relativePath,
  ) async {
    final segments = _segments(relativePath);
    if (segments.isEmpty) return _saf.stat(rootUri);
    return _saf.child(rootUri, segments);
  }

  static Future<bool> exists(String rootUri, String relativePath) async =>
      await _resolve(rootUri, relativePath) != null;

  static Future<bool> isDirectory(String rootUri, String relativePath) async {
    final doc = await _resolve(rootUri, relativePath);
    return doc?.isDir ?? false;
  }

  static Future<DateTime> lastModified(
    String rootUri,
    String relativePath,
  ) async {
    final doc = await _resolve(rootUri, relativePath);
    if (doc == null) return DateTime(2023);
    return DateTime.fromMillisecondsSinceEpoch(doc.lastModified);
  }

  static Future<Uint8List?> readBytes(
    String rootUri,
    String relativePath,
  ) async {
    final doc = await _resolve(rootUri, relativePath);
    if (doc == null || doc.isDir) return null;
    return _saf.readFileBytes(doc.uri);
  }

  static Future<void> writeBytes(
    String rootUri,
    String relativePath,
    List<int> bytes,
  ) async {
    final segments = _segments(relativePath);
    assert(segments.isNotEmpty, 'Cannot write to the root of a SAF tree');
    final name = segments.removeLast();
    final parentUri = segments.isEmpty
        ? rootUri
        : (await _saf.mkdirp(rootUri, segments)).uri;
    await _saf.writeFileBytes(
      parentUri,
      name,
      _mimeFromName(name),
      Uint8List.fromList(bytes),
      overwrite: true,
    );
  }

  static Future<void> delete(String rootUri, String relativePath) async {
    final doc = await _resolve(rootUri, relativePath);
    if (doc == null) return;
    await _saf.delete(doc.uri);
  }

  static Future<void> createDirectory(
    String rootUri,
    String relativePath,
  ) async {
    final segments = _segments(relativePath);
    if (segments.isEmpty) return;
    await _saf.mkdirp(rootUri, segments);
  }

  /// Moves and/or renames the document at [fromRelativePath] to
  /// [toRelativePath], creating any missing intermediate directories.
  ///
  /// Does nothing if no document exists at [fromRelativePath].
  static Future<void> moveOrRename(
    String rootUri,
    String fromRelativePath,
    String toRelativePath,
  ) async {
    final doc = await _resolve(rootUri, fromRelativePath);
    if (doc == null) return;

    final fromSegments = _segments(fromRelativePath);
    final toSegments = _segments(toRelativePath);
    final toName = toSegments.removeLast();
    final fromParentSegments = fromSegments.sublist(0, fromSegments.length - 1);

    var current = doc;
    if (!_listEquals(fromParentSegments, toSegments)) {
      final destDirUri = toSegments.isEmpty
          ? rootUri
          : (await _saf.mkdirp(rootUri, toSegments)).uri;
      current = await _saf.moveTo(current.uri, destDirUri);
    }
    if (current.name != toName) {
      current = await _saf.rename(current.uri, toName);
    }
  }

  /// Lists the immediate children of [relativePath] (or the tree root if
  /// [relativePath] is empty/`/`). Returns an empty list if the directory
  /// doesn't exist.
  static Future<List<SafDocumentFile>> listChildren(
    String rootUri,
    String relativePath,
  ) async {
    final doc = await _resolve(rootUri, relativePath);
    final dirUri = doc?.uri ?? (relativePath.isEmpty ? rootUri : null);
    if (dirUri == null) return const [];
    return _saf.list(dirUri);
  }

  /// Recursively walks [relativePath] (or the tree root), yielding every
  /// descendant with its path relative to [rootUri].
  static Stream<SafWalkEntry> walk(
    String rootUri,
    String relativePath,
  ) async* {
    final doc = await _resolve(rootUri, relativePath);
    final dirUri = doc?.uri ?? (relativePath.isEmpty ? rootUri : null);
    if (dirUri == null) return;

    final prefix = relativePath.endsWith('/') ? relativePath : '$relativePath/';
    await for (final entry in _saf.walk(dirUri)) {
      yield SafWalkEntry(
        file: entry.file,
        relativePath: relativePath.isEmpty
            ? entry.relativePath
            : '$prefix${entry.relativePath}',
      );
    }
  }

  /// Copies the document at [relativePath] to a local filesystem [destPath],
  /// so it can be handed to APIs that need a real path. Does nothing if no
  /// document exists at [relativePath].
  static Future<void> copyToLocalFile(
    String rootUri,
    String relativePath,
    String destPath,
  ) async {
    final doc = await _resolve(rootUri, relativePath);
    if (doc == null || doc.isDir) return;
    await _saf.copyToLocalFile(doc.uri, destPath);
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _mimeFromName(String name) {
    final extension = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'svg' => 'image/svg+xml',
      'pdf' => 'application/pdf',
      'json' => 'application/json',
      _ => 'application/octet-stream',
    };
  }
}
