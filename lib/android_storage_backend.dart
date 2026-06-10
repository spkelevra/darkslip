import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'storage_backend.dart';

/// Android implementation using Storage Access Framework (SAF) via MethodChannel.
class AndroidStorageBackend implements StorageBackend {
  static const MethodChannel _channel = MethodChannel('darkslip/storage');

  /// Completer that resolves when the user picks a folder.
  Completer<String?>? _pickerCompleter;

  AndroidStorageBackend() {
    _channel.setMethodCallHandler(_handleCallback);
  }

  Future<dynamic> _handleCallback(MethodCall call) async {
    switch (call.method) {
      case 'onFolderSelected':
        final uri = call.arguments as String?;
        _pickerCompleter?.complete(uri);
        _pickerCompleter = null;
        break;
    }
  }

  @override
  Future<String?> pickDirectory() async {
    _pickerCompleter = Completer<String?>();
    await _channel.invokeMethod('pickDirectory');
    return await _pickerCompleter!.future;
  }

  @override
  Future<bool> checkAccess(String basePath) async {
    try {
      final result = await _channel.invokeMethod('checkAccess', {'basePath': basePath});
      return result as bool? ?? false;
    } catch (e) {
      debugPrint('SAF checkAccess failed: $e');
      return false;
    }
  }

  @override
  Future<List<StorageEntry>> listDirectory(String basePath, String relativePath) async {
    try {
      final List<dynamic> result = await _channel.invokeMethod('listDirectory', {
        'basePath': basePath,
        'relativePath': relativePath,
      });
      return result.map((e) => StorageEntry(
        name: e['name'] as String,
        isDirectory: e['isDirectory'] as bool,
      )).toList();
    } catch (e) {
      debugPrint('SAF listDirectory failed: $e');
      return [];
    }
  }

  @override
  Future<String> readFile(String basePath, String relativePath) async {
    final result = await _channel.invokeMethod('readFile', {
      'basePath': basePath,
      'relativePath': relativePath,
    });
    return result as String;
  }

  @override
  Future<void> writeFile(String basePath, String relativePath, String content) async {
    await _channel.invokeMethod('writeFile', {
      'basePath': basePath,
      'relativePath': relativePath,
      'content': content,
    });
  }

  @override
  Future<void> createDirectory(String basePath, String relativePath) async {
    await _channel.invokeMethod('createDirectory', {
      'basePath': basePath,
      'relativePath': relativePath,
    });
  }

  @override
  Future<void> deleteEntry(String basePath, String relativePath) async {
    await _channel.invokeMethod('deleteEntry', {
      'basePath': basePath,
      'relativePath': relativePath,
    });
  }

  @override
  Future<void> renameEntry(String basePath, String oldRelativePath, String newName) async {
    await _channel.invokeMethod('renameEntry', {
      'basePath': basePath,
      'oldRelativePath': oldRelativePath,
      'newName': newName,
    });
  }

  @override
  String formatPath(String basePath) {
    // SAF URIs are opaque — show a friendly label instead
    return 'SAF: $basePath';
  }
}
