import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:collection/collection.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saber/components/home/sort_button.dart';
import 'package:saber/data/file_manager/saf_backend.dart';
import 'package:saber/data/nextcloud/saber_syncer.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';

/// A collection of cross-platform utility functions for working with a virtual file system.
class FileManager {
  // disable constructor
  new _();

  static final log = Logger('FileManager');

  static const appRootDirectoryPrefix = 'Saber';

  /// This isn't final because isolates sometimes init multiple times.
  /// Realistically, this value never changes.
  ///
  /// This is either a real filesystem path, or (on Android, if the user has
  /// picked a custom folder) a SAF `content://` tree URI.
  static late String documentsDirectory;

  /// Whether [documentsDirectory] is a SAF tree rather than a real path,
  /// i.e. whether file operations need to go through [SafBackend].
  static bool get _isSaf => SafBackend.isSafPath(documentsDirectory);

  /// See [_isSaf].
  static bool get isSafBackend => _isSaf;

  /// A local cache directory that mirrors files read from a SAF-backed
  /// [documentsDirectory], so that [getFile] can hand a real path to APIs
  /// that need one (image/PDF loaders) regardless of backend.
  ///
  /// Unused when [documentsDirectory] isn't a SAF tree.
  ///
  /// Defaults to an empty string (rather than being `late`) so that reading
  /// [mirrorRootPath] before [init] runs (e.g. in tests that set
  /// [documentsDirectory] directly) doesn't throw; it's never actually
  /// dereferenced unless [documentsDirectory] is a SAF tree.
  static String _mirrorRootPath = '';

  /// See [_mirrorRootPath]. Isolates that re-run [init] need to be given
  /// this explicitly, since SAF platform-channel calls (used to compute it
  /// from scratch) aren't available outside the main isolate.
  static String get mirrorRootPath => _mirrorRootPath;

  static final fileWriteStream = StreamController<FileOperation>.broadcast();

  // TODO(adil192): Implement or remove this
  static String _sanitisePath(String path) => File(path).path;

  /// A regex that matches the file names/paths of asset files,
  /// including previews, e.g. `mynote.sbn2.1`.
  static final assetFileRegex = RegExp(r'\.sbn2?\.[\dp]+$');

  /// Forbidden names for files and directories (on any/all platforms).
  /// These patterns match the base name only (not the full path).
  /// Source: https://stackoverflow.com/a/31976060/
  static List<(String, RegExp)> _getForbiddenFilenamePatterns() => [
    (
      t.home.renameNote.noteNameForbiddenCharacters,
      RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
    ),
    (
      t.home.renameNote.noteNameReserved,
      RegExp(
        r'^((con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?)|\.+$',
        caseSensitive: false,
      ),
    ),
  ];
  static String? validateFilename(String filename) {
    if (filename.isEmpty) return t.home.renameNote.noteNameEmpty;
    for (final (error, regexp) in _getForbiddenFilenamePatterns()) {
      if (regexp.hasMatch(filename)) return error;
    }
    return null;
  }

  static Future<void> init({
    String? documentsDirectory,
    String? mirrorRootPath,
    bool shouldWatchRootDirectory = true,
  }) async {
    FileManager.documentsDirectory =
        documentsDirectory ?? await getDocumentsDirectory();
    FileManager._mirrorRootPath =
        mirrorRootPath ??
        p.join((await getTemporaryDirectory()).path, 'saf_mirror');

    if (shouldWatchRootDirectory) unawaited(watchRootDirectory());
  }

  static Future<String> getDocumentsDirectory() async =>
      stows.customDataDir.value ?? await getDefaultDocumentsDirectory();

  static Future<String> getDefaultDocumentsDirectory() async =>
      '${(await getApplicationDocumentsDirectory()).path}/$appRootDirectoryPrefix';

  /// Whether the directory at the absolute [path] (a real filesystem path,
  /// or a SAF `content://` tree URI) is empty or doesn't exist yet.
  static Future<bool> isDirectoryEmptyAtPath(String path) async {
    if (SafBackend.isSafPath(path)) {
      final children = await SafBackend.listChildren(path, '');
      return children.isEmpty;
    }
    final dir = Directory(path);
    if (!dir.existsSync()) return true;
    return dir.listSync().isEmpty;
  }

  static Future<void> migrateDataDir() async {
    final oldRoot = documentsDirectory;
    final newRoot = await getDocumentsDirectory();
    if (oldRoot == newRoot) return;
    log.info('Migrating data directory from $oldRoot to $newRoot');

    final oldRootIsSaf = SafBackend.isSafPath(oldRoot);
    final newRootIsSaf = SafBackend.isSafPath(newRoot);

    final oldDirEmpty = await isDirectoryEmptyAtPath(oldRoot);
    final newDirEmpty = await isDirectoryEmptyAtPath(newRoot);

    if (!oldDirEmpty && !newDirEmpty) {
      log.severe('New and old data directory aren\'t empty, can\'t migrate');
      return;
    }

    documentsDirectory = newRoot;

    if (oldRootIsSaf || newRootIsSaf) {
      // The mirror cache is keyed by relative path only, so it could hold
      // stale content left over from a previously-picked SAF directory.
      final mirrorDir = Directory(_mirrorRootPath);
      if (mirrorDir.existsSync()) await mirrorDir.delete(recursive: true);
    }

    if (oldDirEmpty) {
      log.fine('Old data directory is empty or missing, nothing to migrate');
      return;
    }

    if (!oldRootIsSaf && !newRootIsSaf) {
      await moveDirContents(
        oldDir: Directory(oldRoot),
        newDir: Directory(newRoot),
      );
      await Directory(oldRoot).delete(recursive: true);
      return;
    }

    // At least one side is a SAF tree: dart:io can't rename across
    // backends, so copy bytes across instead.
    await _migrateTreeContents(oldRoot: oldRoot, newRoot: newRoot);
    await _deleteTreeContents(oldRoot);
  }

  static Future<void> _migrateTreeContents({
    required String oldRoot,
    required String newRoot,
  }) async {
    final oldIsSaf = SafBackend.isSafPath(oldRoot);
    final newIsSaf = SafBackend.isSafPath(newRoot);

    final relativePaths = <String>[];
    if (oldIsSaf) {
      await for (final entry in SafBackend.walk(oldRoot, '')) {
        if (!entry.file.isDir) relativePaths.add('/${entry.relativePath}');
      }
    } else {
      final dir = Directory(oldRoot);
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          relativePaths.add(
            '/${p.relative(entity.path, from: dir.path).replaceAll('\\', '/')}',
          );
        }
      }
    }

    for (final relativePath in relativePaths) {
      final bytes = oldIsSaf
          ? await SafBackend.readBytes(oldRoot, relativePath)
          : await File(oldRoot + relativePath).readAsBytes();
      if (bytes == null) continue;

      if (newIsSaf) {
        await SafBackend.writeBytes(newRoot, relativePath, bytes);
      } else {
        final file = File(newRoot + relativePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      }
    }
  }

  static Future<void> _deleteTreeContents(String root) async {
    if (SafBackend.isSafPath(root)) {
      final children = await SafBackend.listChildren(root, '');
      await Future.wait([
        for (final child in children) SafBackend.delete(root, '/${child.name}'),
      ]);
      return;
    }
    final dir = Directory(root);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  static Future<void> moveDirContents({
    required Directory oldDir,
    required Directory newDir,
  }) async {
    await newDir.create(recursive: true);

    await for (final entity in oldDir.list(recursive: true)) {
      // Get the path under oldDir and map it into newDir.
      final relative = p.relative(entity.path, from: oldDir.path);
      final targetPath = p.join(newDir.path, relative);

      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
        continue;
      }

      if (entity is File) {
        // Ensure parent exists
        await entity.parent.create(recursive: true);

        try {
          await entity.rename(targetPath);
        } on FileSystemException catch (e) {
          // Cross device move, eg. private to public on android
          const exdev = 18;
          if (e.osError?.errorCode == exdev) {
            await entity.copy(targetPath);
            await entity.delete();
          } else {
            rethrow;
          }
        }
      }
    }
  }

  @visibleForTesting
  static Future<void> watchRootDirectory() async {
    // There's no native filesystem-watch API for SAF trees; writes made
    // through FileManager already broadcast explicitly, so only external
    // changes to the custom directory go unnoticed.
    if (_isSaf) return;

    final rootDir = Directory(documentsDirectory);
    await rootDir.create(recursive: true);
    if (Platform.isIOS) return;
    rootDir.watch(recursive: true).listen((event) {
      final FileOperationType type = switch (event.type) {
        FileSystemEvent.delete => .delete,
        FileSystemEvent.create => .write,
        FileSystemEvent.modify => .write,
        FileSystemEvent.move => .write,
        _ =>
          kDebugMode
              ? throw UnimplementedError(
                  'Unhandled FileSystemEvent type: ${event.type}',
                )
              : .write,
      };
      final String path = event.path
          .replaceAll('\\', '/')
          // The path may or may not be relative,
          // so remove the root directory path to make sure it's relative.
          .replaceFirst(documentsDirectory, '');
      broadcastFileWrite(type, path);
    });
  }

  @visibleForTesting
  static void broadcastFileWrite(FileOperationType type, String path) async {
    if (!fileWriteStream.hasListener) return;

    // remove extension
    if (path.endsWith(Editor.extension)) {
      path = path.substring(0, path.length - Editor.extension.length);
    } else if (path.endsWith(Editor.extensionOldJson)) {
      path = path.substring(0, path.length - Editor.extensionOldJson.length);
    }

    fileWriteStream.add(FileOperation(type, path));
  }

  // The following private helpers are the single choke point where
  // FileManager's file-level operations (read/write/delete/move) dispatch
  // between real dart:io paths and a SAF-backed [documentsDirectory]. They
  // also keep the local mirror cache (see [_mirrorRootPath]) in sync so
  // [getFile] can keep returning a real, already-populated File either way.

  static Future<bool> _exists(String filePath) async {
    if (_isSaf) return SafBackend.exists(documentsDirectory, filePath);
    return getFile(filePath).existsSync();
  }

  static Future<void> _writeBytes(String filePath, List<int> bytes) async {
    if (_isSaf) {
      await SafBackend.writeBytes(documentsDirectory, filePath, bytes);
      final mirrorFile = File(_mirrorRootPath + filePath);
      await mirrorFile.parent.create(recursive: true);
      await mirrorFile.writeAsBytes(bytes);
      return;
    }
    await getFile(filePath).writeAsBytes(bytes);
  }

  static Future<void> _delete(String filePath) async {
    if (_isSaf) {
      await SafBackend.delete(documentsDirectory, filePath);
      final mirrorFile = File(_mirrorRootPath + filePath);
      if (mirrorFile.existsSync()) await mirrorFile.delete();
      return;
    }
    final file = getFile(filePath);
    if (file.existsSync()) await file.delete();
  }

  static Future<void> _moveOrRename(String fromPath, String toPath) async {
    if (_isSaf) {
      await SafBackend.moveOrRename(documentsDirectory, fromPath, toPath);
      final fromMirror = File(_mirrorRootPath + fromPath);
      if (fromMirror.existsSync()) {
        final toMirror = File(_mirrorRootPath + toPath);
        await toMirror.parent.create(recursive: true);
        try {
          await fromMirror.rename(toMirror.path);
        } on FileSystemException {
          // Best-effort; a stale/missing mirror entry just means the next
          // read re-fetches from the SAF tree.
        }
      }
      return;
    }
    final fromFile = getFile(fromPath);
    final toFile = getFile(toPath);
    await toFile.parent.create(recursive: true);
    await fromFile.rename(toFile.path);
  }

  static Future<void> _mkdir(String folderPath) async {
    if (_isSaf) {
      await SafBackend.createDirectory(documentsDirectory, folderPath);
      return;
    }
    await Directory(documentsDirectory + folderPath).create(recursive: true);
  }

  /// For a SAF-backed [documentsDirectory], copies the document at
  /// [filePath] into the local mirror cache so [getFile] can hand a real
  /// path to APIs that need one (image/PDF loaders). No-op otherwise, or if
  /// no document exists at [filePath].
  static Future<void> ensureMirrored(String filePath) async {
    if (!_isSaf) return;
    final mirrorFile = File(_mirrorRootPath + filePath);
    if (!await SafBackend.exists(documentsDirectory, filePath)) {
      if (mirrorFile.existsSync()) await mirrorFile.delete();
      return;
    }
    await mirrorFile.parent.create(recursive: true);
    await SafBackend.copyToLocalFile(
      documentsDirectory,
      filePath,
      mirrorFile.path,
    );
  }

  /// For a SAF-backed [documentsDirectory], mirrors every asset file
  /// (`$notePath.0`, `$notePath.1`, ..., `$notePath.p`) belonging to the
  /// note at [notePath] (which must include its extension) into the local
  /// mirror cache, so they're available as real files by the time the
  /// note's images are deserialized (possibly on a background isolate).
  /// No-op otherwise.
  static Future<void> prefetchNoteAssets(String notePath) async {
    if (!_isSaf) return;

    final parentPath = notePath.substring(0, notePath.lastIndexOf('/') + 1);
    final children = await SafBackend.listChildren(
      documentsDirectory,
      parentPath,
    );
    final assetPrefix = '$notePath.';

    await Future.wait([
      for (final child in children)
        if (!child.isDir && '$parentPath${child.name}'.startsWith(assetPrefix))
          ensureMirrored('$parentPath${child.name}'),
    ]);
  }

  /// Returns the contents of the file at [filePath].
  static Future<Uint8List?> readFile(String filePath, {int retries = 3}) async {
    filePath = _sanitisePath(filePath);

    Uint8List? result;
    if (await _exists(filePath)) {
      result = _isSaf
          ? await SafBackend.readBytes(documentsDirectory, filePath)
          : await getFile(filePath).readAsBytes();
      if (result != null && result.isEmpty) result = null;
    } else {
      retries = 0; // don't retry if the file doesn't exist
    }

    // If result is null, try again in case the file was locked.
    if (result == null && retries > 0) {
      await Future.delayed(const Duration(milliseconds: 100));
      return readFile(filePath, retries: retries - 1);
    }
    return result;
  }

  /// Whether getFile should just return File(filePath)
  /// instead of prefixing with the documents directory.
  /// This is useful for testing when test files
  /// aren't in the documents directory.
  @visibleForTesting
  static var shouldUseRawFilePath = false;

  static File getFile(String filePath) {
    if (shouldUseRawFilePath) {
      return File(filePath);
    } else {
      assert(
        filePath.startsWith('/'),
        'Expected filePath to start with a slash, got $filePath',
      );
      // SAF documents can't be addressed by dart:io File under scoped
      // storage, so hand back a File in the local mirror cache instead.
      if (_isSaf) return File(_mirrorRootPath + filePath);
      return File(documentsDirectory + filePath);
    }
  }

  static Directory getRootDirectory() => Directory(documentsDirectory);

  /// Writes [toWrite] to [filePath].
  ///
  /// The file at [toPath] will have its last modified timestamp set to
  /// [lastModified], if specified.
  /// This is useful when downloading remote files, to make sure that the
  /// timestamp is the same locally and remotely.
  static Future<void> writeFile(
    String filePath,
    List<int> toWrite, {
    bool awaitWrite = false,
    bool alsoUpload = true,
    DateTime? lastModified,
  }) async {
    filePath = _sanitisePath(filePath);
    log.fine('Writing to $filePath');

    await _saveFileAsRecentlyAccessed(filePath);

    await _createFileDirectory(filePath);
    Future writeFuture = Future.wait([
      _writeBytes(filePath, toWrite).then((_) async {
        if (lastModified != null && !_isSaf) {
          await getFile(filePath).setLastModified(lastModified);
        }
      }),
      // if we're using a new format, also delete the old file
      if (filePath.endsWith(Editor.extension))
        _delete(
          '${filePath.substring(0, filePath.length - Editor.extension.length)}'
          '${Editor.extensionOldJson}',
        ),
    ]);

    void afterWrite() {
      broadcastFileWrite(FileOperationType.write, filePath);
      if (alsoUpload) syncer.uploader.enqueueRel(filePath);
      if (filePath.endsWith(Editor.extension)) {
        _removeReferences(
          '${filePath.substring(0, filePath.length - Editor.extension.length)}'
          '${Editor.extensionOldJson}',
        );
      }
    }

    writeFuture = writeFuture.then((_) => afterWrite());
    if (awaitWrite) await writeFuture;
  }

  static Future<void> createFolder(String folderPath) async {
    folderPath = _sanitisePath(folderPath);
    await _mkdir(folderPath);
  }

  static Future exportFile(
    String fileName,
    Uint8List bytes, {
    bool isImage = false,
    required BuildContext context,
  }) async {
    File? tempFile;
    Future<File> getTempFile() async {
      final tempFolder = (await getTemporaryDirectory()).path;
      final file = File('$tempFolder/$fileName');
      await file.writeAsBytes(bytes);
      return file;
    }

    if (Platform.isAndroid || Platform.isIOS) {
      if (isImage) {
        // request permission
        final permissionGranted = await _requestPhotosPermission();
        // save image to gallery
        if (permissionGranted) {
          await SaverGallery.saveImage(
            Uint8List.fromList(bytes),
            fileName: fileName,
            albumPath: 'Saber',
            skipIfExists: true,
          );
        }
      } else {
        // share file
        tempFile = await getTempFile();
        if (Platform.isIOS || Platform.isMacOS) {
          if (!context.mounted) return;
          final box = context.findRenderObject() as RenderBox;
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(tempFile.path)],
              // iOS requires a sharePositionOrigin for the share sheet to appear
              sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
            ),
          );
        } else {
          await SharePlus.instance.share(
            ShareParams(files: [XFile(tempFile.path)]),
          );
        }
      }
    } else {
      // desktop, open save-as dialog
      await FilePicker.saveFile(
        fileName: fileName,
        initialDirectory: (await getDownloadsDirectory())?.path,
        type: FileType.custom,
        allowedExtensions: [fileName.split('.').last],
        bytes: bytes,
      );
    }

    // delete temp file if it isn't null
    await tempFile?.delete();
  }

  static Future<bool> _requestPhotosPermission() async {
    if (Platform.isIOS) {
      return await Permission.photosAddOnly.request().isGranted;
    } else if (!Platform.isAndroid) {
      return true;
    }

    final sdkInt = await DeviceInfoPlugin().androidInfo.then(
      (info) => info.version.sdkInt,
    );
    if (sdkInt > 33) {
      return await Permission.photos.request().isGranted;
    } else {
      return await Permission.storage.request().isGranted;
    }
  }

  /// Moves a file from [fromPath] to [toPath], returning its final path.
  ///
  /// If a file already exists at [toPath], [fromPath] will be suffixed with
  /// a number e.g. "file (1)". If [replaceExistingFile] is true, the existing
  /// file will be overwritten instead.
  ///
  /// If [replaceExistingFile] is true but the file is a reserved file name,
  /// the filename will be suffixed with a number instead
  /// (like if [replaceExistingFile] was false).
  static Future<String> moveFile(
    String fromPath,
    String toPath, {
    bool replaceExistingFile = false,
    bool alsoMoveAssets = true,
  }) async {
    fromPath = _sanitisePath(fromPath);
    toPath = _sanitisePath(toPath);

    if (!toPath.contains('/')) {
      // if toPath is a relative path
      toPath = fromPath.substring(0, fromPath.lastIndexOf('/') + 1) + toPath;
    }

    if (!replaceExistingFile || Editor.isReservedPath(toPath)) {
      toPath = await suffixFilePathToMakeItUnique(
        toPath,
        currentPath: fromPath,
      );
    }

    if (fromPath == toPath) return toPath;

    if (await _exists(fromPath)) {
      await _moveOrRename(fromPath, toPath);
    } else {
      log.warning('Tried to move non-existent file from $fromPath to $toPath');
    }

    syncer.uploader.enqueueRel(fromPath);
    syncer.uploader.enqueueRel(toPath);

    _renameReferences(fromPath, toPath);
    broadcastFileWrite(FileOperationType.delete, fromPath);
    broadcastFileWrite(FileOperationType.write, toPath);

    if (alsoMoveAssets && !assetFileRegex.hasMatch(fromPath)) {
      final assets = <String>[];
      for (int assetNumber = 0; true; assetNumber++) {
        if (await _exists('$fromPath.$assetNumber')) {
          assets.add('$assetNumber');
        } else {
          break;
        }
      }
      if (await _exists('$fromPath.p')) {
        assets.add('p');
      }

      await Future.wait([
        for (final assetNumber in assets)
          moveFile(
            '$fromPath.$assetNumber',
            '$toPath.$assetNumber',
            replaceExistingFile: replaceExistingFile,
          ),
      ]);
    }

    return toPath;
  }

  static Future deleteFile(
    String filePath, {
    bool alsoUpload = true,
    bool alsoDeleteAssets = true,
  }) async {
    filePath = _sanitisePath(filePath);

    if (!await _exists(filePath)) return;
    await _delete(filePath);

    if (alsoUpload) syncer.uploader.enqueueRel(filePath);

    _removeReferences(filePath);
    broadcastFileWrite(FileOperationType.delete, filePath);

    if (alsoDeleteAssets && !assetFileRegex.hasMatch(filePath)) {
      final assets = <int>[];
      for (int assetNumber = 0; true; assetNumber++) {
        if (await _exists('$filePath.$assetNumber')) {
          assets.add(assetNumber);
        } else {
          break;
        }
      }

      final hasPreview = await _exists('$filePath.p');
      await Future.wait([
        for (final assetNumber in assets)
          deleteFile('$filePath.$assetNumber', alsoDeleteAssets: false),
        if (hasPreview) deleteFile('$filePath.p', alsoDeleteAssets: false),
      ]);
    }
  }

  static Future removeUnusedAssets(
    String filePath, {
    required int numAssets,
  }) async {
    final futures = <Future>[];

    for (int assetNumber = numAssets; true; assetNumber++) {
      final assetPath = '$filePath.$assetNumber';
      if (await _exists(assetPath)) {
        futures.add(deleteFile(assetPath));
      } else {
        break;
      }
    }

    await Future.wait(futures);
  }

  static Future renameDirectory(String directoryPath, String newName) async {
    directoryPath = _sanitisePath(directoryPath);

    if (!await isDirectory(directoryPath)) return;

    final String newPath =
        directoryPath.substring(0, directoryPath.lastIndexOf('/') + 1) +
        newName;

    /// recursively find children of [directoryPath] for [_renameReferences]
    final List<String> children = [];
    if (_isSaf) {
      await for (final entry in SafBackend.walk(
        documentsDirectory,
        directoryPath,
      )) {
        if (entry.file.isDir) continue;
        final child = entry.relativePath.substring(directoryPath.length);
        children.add(child.startsWith('/') ? child : '/$child');
      }
      await SafBackend.moveOrRename(documentsDirectory, directoryPath, newPath);
      final mirrorDir = Directory(_mirrorRootPath + directoryPath);
      if (mirrorDir.existsSync()) await mirrorDir.delete(recursive: true);
    } else {
      final directory = Directory(documentsDirectory + directoryPath);
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          children.add(entity.path.substring(directory.path.length));
        }
      }
      await directory.rename(documentsDirectory + newPath);
    }

    for (final child in children) {
      _renameReferences(directoryPath + child, newPath + child);
      broadcastFileWrite(FileOperationType.delete, directoryPath + child);
      broadcastFileWrite(FileOperationType.write, newPath + child);
    }
  }

  static Future deleteDirectory(
    String directoryPath, [
    bool recursive = true,
  ]) async {
    directoryPath = _sanitisePath(directoryPath);

    if (!await isDirectory(directoryPath)) return;

    if (recursive) {
      // call [deleteFile] on all files that are descendants of the directory
      if (_isSaf) {
        await for (final entry in SafBackend.walk(
          documentsDirectory,
          directoryPath,
        )) {
          if (!entry.file.isDir) await deleteFile(entry.relativePath);
        }
      } else {
        final directory = Directory(documentsDirectory + directoryPath);
        await for (final entity in directory.list(recursive: true)) {
          if (entity is File) {
            await deleteFile(entity.path.substring(documentsDirectory.length));
          }
        }
      }
    }

    if (_isSaf) {
      await SafBackend.delete(documentsDirectory, directoryPath);
      final mirrorDir = Directory(_mirrorRootPath + directoryPath);
      if (mirrorDir.existsSync()) await mirrorDir.delete(recursive: true);
    } else {
      await Directory(
        documentsDirectory + directoryPath,
      ).delete(recursive: recursive);
    }
  }

  /// Gets the children of a directory, separated into
  /// [DirectoryChildren.directories] and [DirectoryChildren.files].
  ///
  /// If [includeExtensions] is false (default), the extension will be removed
  /// from the file names. We use this to get all notes in a directory.
  ///
  /// If [includeAssets] is true, assets and previews will be included.
  /// We use this for syncing.
  ///
  /// Note: [includeAssets] can't be true without [includeExtension],
  /// since otherwise we wouldn't be able to tell the difference between notes
  /// and assets.
  static Future<DirectoryChildren?> getChildrenOfDirectory(
    String directory, {
    bool includeExtensions = false,
    bool includeAssets = false,
    SortMetric sortMetric = .nameAToZ,
  }) async {
    assert(
      !includeAssets || includeExtensions,
      'includeAssets can\'t be true without includeExtensions',
    );

    directory = _sanitisePath(directory);
    if (!directory.endsWith('/')) directory += '/';

    final List<String> directories = [], files = [];

    if (!await isDirectory(directory)) return null;

    final int directoryPrefixLength = directory.length;

    String? processEntry(String filePath, {required bool isDirectoryEntry}) {
      // directories don't need any further processing
      if (isDirectoryEntry) return filePath;

      // filter out reserved files
      if (Editor.isReservedPath(filePath)) return null;

      final isSbn2 = filePath.endsWith(Editor.extension);
      final isSbn1 = filePath.endsWith(Editor.extensionOldJson);

      if (!includeExtensions) {
        if (isSbn2) {
          return filePath.substring(
            0,
            filePath.length - Editor.extension.length,
          );
        } else if (isSbn1) {
          return filePath.substring(
            0,
            filePath.length - Editor.extensionOldJson.length,
          );
        } else {
          return null; // filePath is name of some asset
        }
      } else if (!includeAssets) {
        final isAsset = !isSbn2 && !isSbn1;
        if (isAsset) return null;
      }

      return filePath;
    }

    final List<String?> rawEntries;
    if (_isSaf) {
      final children = await SafBackend.listChildren(
        documentsDirectory,
        directory,
      );
      rawEntries = [
        for (final child in children)
          processEntry(
            '$directory${child.name}',
            isDirectoryEntry: child.isDir,
          ),
      ];
    } else {
      final dir = Directory(documentsDirectory + directory);
      rawEntries = await dir
          .list()
          .map((FileSystemEntity entity) {
            final filePath = entity.path.substring(documentsDirectory.length);
            return processEntry(filePath, isDirectoryEntry: entity is Directory);
          })
          .toList();
    }

    final allChildren = rawEntries
        .where((String? file) => file != null)
        // remove parent folder
        .map((file) => file!.substring(directoryPrefixLength))
        .toList();

    for (final child in allChildren) {
      if (await FileManager.isDirectory(directory + child) &&
          !directories.contains(child)) {
        directories.add(child);
      } else if (!includeAssets && assetFileRegex.hasMatch(child)) {
        // if the file is an asset, don't add it to the list of files
      } else {
        files.add(child);
      }
    }

    switch (sortMetric) {
      case .nameAToZ:
        directories.sort();
        files.sort();
      case .nameZToA:
        directories.sort((child, other) => -child.compareTo(other));
        files.sort((child, other) => -child.compareTo(other));
      case .lastModifiedNewToOld:
      case .lastModifiedOldToNew:
        directories.sort();
        final modified = <String, DateTime>{
          for (final child in files)
            child: await lastModified(directory + child + Editor.extension),
        };
        if (sortMetric == SortMetric.lastModifiedNewToOld) {
          files.sort((a, b) => -modified[a]!.compareTo(modified[b]!));
        } else {
          files.sort((a, b) => modified[a]!.compareTo(modified[b]!));
        }
    }

    return DirectoryChildren(directories, files);
  }

  /// Returns a list of all files recursively in the root directory.
  ///
  /// See [getChildrenOfDirectory] for more information on the parameters.
  static Future<List<String>> getAllFiles({
    bool includeExtensions = false,
    bool includeAssets = false,
  }) async {
    final allFiles = <String>[];
    final directories = <String>['/'];

    while (directories.isNotEmpty) {
      final directory = directories.removeLast();
      final children = await getChildrenOfDirectory(
        directory,
        includeExtensions: includeExtensions,
        includeAssets: includeAssets,
      );
      if (children == null) continue;

      for (final file in children.files) {
        allFiles.add('$directory$file');
      }
      for (final childDirectory in children.directories) {
        directories.add('$directory$childDirectory/');
      }
    }

    return allFiles;
  }

  static Future<List<String>> getRecentlyAccessed() async {
    if (!stows.recentFiles.loaded) await stows.recentFiles.waitUntilRead();
    // Delete entries for files that have been deleted outside of Saber
    for (final file in stows.recentFiles.value.toList()) {
      if (!await doesFileExist(file)) _removeReferences(file);
    }
    return stows.recentFiles.value
        .map((String filePath) {
          if (filePath.endsWith(Editor.extension)) {
            return filePath.substring(
              0,
              filePath.length - Editor.extension.length,
            );
          } else if (filePath.endsWith(Editor.extensionOldJson)) {
            return filePath.substring(
              0,
              filePath.length - Editor.extensionOldJson.length,
            );
          } else {
            return filePath;
          }
        })
        .where(
          (String file) => !Editor.isReservedPath(file),
        ) // filter out reserved file names
        .toList();
  }

  /// Returns whether the [filePath] is a directory or file.
  /// Behaviour is undefined if [filePath] is not a valid path.
  static Future<bool> isDirectory(String filePath) async {
    filePath = _sanitisePath(filePath);
    if (_isSaf) return SafBackend.isDirectory(documentsDirectory, filePath);
    return Directory(documentsDirectory + filePath).existsSync();
  }

  static Future<bool> doesFileExist(String filePath) async {
    filePath = _sanitisePath(filePath);
    return _exists(filePath);
  }

  static Future<DateTime> lastModified(String filePath) async {
    filePath = _sanitisePath(filePath);
    if (_isSaf) return SafBackend.lastModified(documentsDirectory, filePath);
    final file = getFile(filePath);
    if (!file.existsSync()) return DateTime(2023);
    return file.lastModifiedSync();
  }

  static Future<String> newFilePath([String parentPath = '/']) async {
    assert(parentPath.endsWith('/'));

    final DateTime now = DateTime.now();
    final String filePath =
        '$parentPath${DateFormat("yy-MM-dd").format(now)} '
        '${t.editor.untitled}';

    return await suffixFilePathToMakeItUnique(filePath);
  }

  /// Returns a unique file path by appending a number to the end of the [filePath].
  /// e.g. "/Untitled" -> "/Untitled (2)"
  ///
  /// Providing a [currentPath] means that e.g. "/Untitled (2)" being renamed
  /// to "/Untitled" will be returned as "/Untitled (2)" not "/Untitled (3)".
  ///
  /// If [currentPath] is provided, it must
  /// end with [Editor.extension] or [Editor.extensionOldJson].
  static Future<String> suffixFilePathToMakeItUnique(
    String filePath, {
    String? intendedExtension,
    String? currentPath,
  }) async {
    String newFilePath = filePath;
    bool hasExtension = false;

    if (filePath.endsWith(Editor.extension)) {
      filePath = filePath.substring(
        0,
        filePath.length - Editor.extension.length,
      );
      newFilePath = filePath;
      hasExtension = true;
      intendedExtension ??= Editor.extension;
    } else if (filePath.endsWith(Editor.extensionOldJson)) {
      filePath = filePath.substring(
        0,
        filePath.length - Editor.extensionOldJson.length,
      );
      newFilePath = filePath;
      hasExtension = true;
      intendedExtension ??= Editor.extensionOldJson;
    } else {
      intendedExtension ??= Editor.extension;
    }

    int i = 1;
    while (true) {
      if (!await doesFileExist(newFilePath + Editor.extension) &&
          !await doesFileExist(newFilePath + Editor.extensionOldJson))
        break;
      if (newFilePath + Editor.extension == currentPath) break;
      if (newFilePath + Editor.extensionOldJson == currentPath) break;
      i++;
      newFilePath = '$filePath ($i)';
    }

    return newFilePath + (hasExtension ? intendedExtension : '');
  }

  /// Imports a file from a sharing intent.
  ///
  /// [parentDir], if provided, must start and end with a slash.
  ///
  /// [extension], if provided, must start with a dot.
  /// If not provided, it will be inferred from the [path].
  ///
  /// Returns the file path of the imported file.
  static Future<String?> importFile(
    String path,
    String? parentDir, {
    String? extension,
    bool awaitWrite = true,
  }) async {
    assert(
      parentDir == null || parentDir.startsWith('/') && parentDir.endsWith('/'),
    );

    if (extension == null) {
      extension = '.${path.split('.').last}';
      assert(extension.length > 1);
    } else {
      assert(extension.startsWith('.')); // extension must start with a dot
    }

    /// The file name without its extension
    String fileName = path.split(RegExp(r'[\\/]')).last;
    fileName = fileName.substring(0, fileName.lastIndexOf('.'));
    final String importedPath;

    final writeFutures = <Future>[];

    if (extension.toLowerCase() == '.sba') {
      final inputStream = InputFileStream(path);
      final archive = ZipDecoder().decodeStream(inputStream);

      final mainFile = archive.files.cast<ArchiveFile?>().firstWhere(
        (file) =>
            file!.name.toLowerCase().endsWith('sbn') ||
            file.name.toLowerCase().endsWith('sbn2'),
        orElse: () => null,
      );
      if (mainFile == null) {
        log.severe('Failed to find main note in sba: $path');
        return null;
      }
      final mainFileExtension = '.${mainFile.name.split('.').last}'
          .toLowerCase();
      importedPath = await suffixFilePathToMakeItUnique(
        '${parentDir ?? '/'}$fileName',
        intendedExtension: mainFileExtension,
      );
      final mainFileContents = () {
        final output = OutputMemoryStream();
        mainFile.writeContent(output);
        return output.getBytes();
      }();
      writeFutures.add(
        writeFile(
          importedPath + mainFileExtension,
          mainFileContents,
          awaitWrite: awaitWrite,
        ),
      );

      // now import assets
      for (final file in archive.files) {
        if (!file.isFile) continue;
        if (file == mainFile) continue;

        final extension = file.name.split('.').last;
        final assetNumber = int.tryParse(extension);
        if (assetNumber == null) continue;
        if (assetNumber < 0) continue;

        final assetBytes = () {
          final output = OutputMemoryStream();
          file.writeContent(output);
          return output.getBytes();
        }();
        writeFutures.add(
          writeFile(
            '$importedPath$mainFileExtension.$assetNumber',
            assetBytes,
            awaitWrite: awaitWrite,
          ),
        );
      }
    } else {
      // import sbn or sbn2
      final file = File(path);
      final fileContents = await file.readAsBytes();
      importedPath = await suffixFilePathToMakeItUnique(
        '${parentDir ?? '/'}$fileName',
        intendedExtension: extension.toLowerCase(),
      );
      writeFutures.add(
        writeFile(
          importedPath + extension.toLowerCase(),
          fileContents,
          awaitWrite: awaitWrite,
        ),
      );
    }

    await Future.wait(writeFutures);

    return importedPath;
  }

  /// Creates the parent directories of filePath if they don't exist.
  static Future _createFileDirectory(String filePath) async {
    assert(filePath.contains('/'), 'filePath must be a path, not a file name');
    final parentDirectory = filePath.substring(0, filePath.lastIndexOf('/'));
    await _mkdir(parentDirectory);
  }

  static Future _renameReferences(String fromPath, String toPath) async {
    // rename file in recently accessed
    bool replaced = false;
    for (int i = 0; i < stows.recentFiles.value.length; i++) {
      if (stows.recentFiles.value[i] != fromPath) continue;
      if (!replaced) {
        stows.recentFiles.value[i] = toPath;
        replaced = true;
      } else {
        stows.recentFiles.value.removeAt(i);
      }
    }
    stows.recentFiles.notifyListeners();
  }

  static Future _removeReferences(String filePath) async {
    // remove file from recently accessed
    for (int i = 0; i < stows.recentFiles.value.length; i++) {
      if (stows.recentFiles.value[i] != filePath) continue;
      stows.recentFiles.value.removeAt(i);
    }
    stows.recentFiles.notifyListeners();
  }

  static Future _saveFileAsRecentlyAccessed(String filePath) async {
    // don't add assets to recently accessed
    if (assetFileRegex.hasMatch(filePath)) return;

    stows.recentFiles.value.remove(filePath);
    stows.recentFiles.value.insert(0, filePath);
    if (stows.recentFiles.value.length > maxRecentlyAccessedFiles)
      stows.recentFiles.value.removeLast();

    stows.recentFiles.notifyListeners();
  }

  static const maxRecentlyAccessedFiles = 30;
}

class DirectoryChildren {
  final List<String> directories;
  final List<String> files;

  new(this.directories, this.files);

  bool onlyOneChild() => directories.length + files.length <= 1;

  bool get isEmpty => directories.isEmpty && files.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

enum FileOperationType { write, delete }

class FileOperation {
  final FileOperationType type;
  final String filePath;

  const new(this.type, this.filePath);
}
