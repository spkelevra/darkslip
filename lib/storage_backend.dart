import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_package;

/// Describes a single entry returned by [StorageBackend.listDirectory].
class StorageEntry {
  final String name;
  final bool isDirectory;

  StorageEntry({required this.name, required this.isDirectory});
}

/// Platform-agnostic storage abstraction.
/// Each platform provides its own implementation:
///   - Android → SAF (ContentResolver / UriTreeDocument)
///   - Windows/Desktop → dart:io file system
abstract class StorageBackend {
  /// Pick a directory using the native folder picker. Returns the resolved path/URI string, or null if cancelled.
  Future<String?> pickDirectory();

  /// Check whether the current [basePath] is accessible (read + write).
  Future<bool> checkAccess(String basePath);

  /// List entries inside [relativePath] under [basePath].
  /// Pass '' for the root of the base directory.
  Future<List<StorageEntry>> listDirectory(String basePath, String relativePath);

  /// Read a file at [relativePath] under [basePath], returning its text content.
  Future<String> readFile(String basePath, String relativePath);

  /// Write [content] to a file at [relativePath] under [basePath].
  /// Creates parent directories as needed.
  Future<void> writeFile(String basePath, String relativePath, String content);

  /// Create a directory at [relativePath] under [basePath].
  Future<void> createDirectory(String basePath, String relativePath);

  /// Delete the entry (file or directory) at [relativePath] under [basePath].
  /// If it is a directory, deletes recursively.
  Future<void> deleteEntry(String basePath, String relativePath);

  /// Rename an entry from [oldRelativePath] to [newName] within the same parent directory.
  Future<void> renameEntry(String basePath, String oldRelativePath, String newName);

  /// Build a display-friendly path string for the user (e.g., in Settings).
  String formatPath(String basePath);
}

/// dart:io-based implementation for Windows / desktop platforms.
class DesktopStorageBackend implements StorageBackend {
  @override
  Future<String?> pickDirectory() async {
    // On desktop we delegate to the file_picker plugin (called from Dart side).
    // This method is a no-op here; the caller uses [DesktopFolderPicker.pick] instead.
    return null;
  }

  @override
  Future<bool> checkAccess(String basePath) async {
    try {
      final dir = Directory(basePath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final testFile = File(path_package.join(basePath, '.write_test'));
      await testFile.writeAsString('ok');
      await testFile.delete();
      return true;
    } catch (e) {
      debugPrint('Desktop storage check failed: $e');
      return false;
    }
  }

  @override
  Future<List<StorageEntry>> listDirectory(String basePath, String relativePath) async {
    final fullPath = relativePath.isEmpty ? basePath : path_package.join(basePath, relativePath);
    final dir = Directory(fullPath);
    if (!await dir.exists()) return [];

    final entries = <StorageEntry>[];
    await for (var entity in dir.list()) {
      final name = path_package.basename(entity.path);
      // Skip hidden files
      if (name.startsWith('.')) continue;
      entries.add(StorageEntry(
        name: name,
        isDirectory: entity is Directory,
      ));
    }
    return entries;
  }

  @override
  Future<String> readFile(String basePath, String relativePath) async {
    final fullPath = path_package.join(basePath, relativePath);
    return await File(fullPath).readAsString();
  }

  @override
  Future<void> writeFile(String basePath, String relativePath, String content) async {
    final fullPath = path_package.join(basePath, relativePath);
    final dir = Directory(path_package.dirname(fullPath));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await File(fullPath).writeAsString(content);
  }

  @override
  Future<void> createDirectory(String basePath, String relativePath) async {
    final fullPath = path_package.join(basePath, relativePath);
    await Directory(fullPath).create(recursive: true);
  }

  @override
  Future<void> deleteEntry(String basePath, String relativePath) async {
    final fullPath = path_package.join(basePath, relativePath);
    final entity = FileSystemEntity.typeSync(fullPath);
    if (entity == FileSystemEntityType.directory) {
      await Directory(fullPath).delete(recursive: true);
    } else {
      await File(fullPath).delete();
    }
  }

  @override
  Future<void> renameEntry(String basePath, String oldRelativePath, String newName) async {
    final oldFullPath = path_package.join(basePath, oldRelativePath);
    final parentDir = path_package.dirname(oldFullPath);
    final newFullPath = path_package.join(parentDir, newName);
    await FileSystemEntity.type(oldFullPath).then((type) {
      if (type == FileSystemEntityType.directory) {
        return Directory(oldFullPath).rename(newFullPath);
      } else {
        return File(oldFullPath).rename(newFullPath);
      }
    });
  }

  @override
  String formatPath(String basePath) => basePath;
}
