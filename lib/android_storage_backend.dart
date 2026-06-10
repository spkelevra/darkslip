import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'storage_backend.dart';

/// Android implementation using Storage Access Framework (SAF) via MethodChannel.
class AndroidStorageBackend implements StorageBackend {
  static const MethodChannel _channel = MethodChannel('darkslip/storage');

  /// Completer that resolves when the user picks a folder.
  Completer<String?>? _pickerCompleter;

  /// Cached tree URI from Kotlin side — avoids passing it in every call.
  String? _cachedTreeUri;

  AndroidStorageBackend() {
    _channel.setMethodCallHandler(_handleCallback);
  }

  Future<dynamic> _handleCallback(MethodCall call) async {
    switch (call.method) {
      case 'onFolderSelected':
        final uri = call.arguments as String?;
        _cachedTreeUri = uri;
        _pickerCompleter?.complete(uri);
        _pickerCompleter = null;
        break;
    }
  }

  /// Ask Kotlin for the persisted tree URI (survives process death).
  Future<String?> getSavedTreeUri() async {
    // Return cached value if we already have it from a picker session
    if (_cachedTreeUri != null) return _cachedTreeUri;

    try {
      final result = await _channel.invokeMethod('getSavedTreeUri');
      _cachedTreeUri = result as String?;
      return _cachedTreeUri;
    } catch (e) {
      debugPrint('SAF getSavedTreeUri failed: $e');
      return null;
    }
  }

  @override
  Future<String?> pickDirectory() async {
    _pickerCompleter = Completer<String?>();
    await _channel.invokeMethod('pickDirectory');
    final result = await _pickerCompleter!.future;
    _cachedTreeUri = result;
    return result;
  }

  /// Resolve the basePath: if null/empty, use the Kotlin-persisted URI.
  Future<String?> _resolveBasePath(String? basePath) async {
    if (basePath != null && basePath.isNotEmpty) {
      // If it looks like a content:// URI, use it directly
      if (basePath.startsWith('content://')) return basePath;
      // Otherwise it's likely an old raw path — fall through to cached URI
      debugPrint('[AndroidStorageBackend] basePath is not a content URI, using persisted tree URI');
    }
    return await getSavedTreeUri();
  }

  @override
  Future<bool> checkAccess(String basePath) async {
    try {
      final resolved = await _resolveBasePath(basePath);
      if (resolved == null) return false;
      final result = await _channel.invokeMethod('checkAccess', {'basePath': resolved});
      return result as bool? ?? false;
    } catch (e) {
      debugPrint('SAF checkAccess failed: $e');
      return false;
    }
  }

  @override
  Future<List<StorageEntry>> listDirectory(String basePath, String relativePath) async {
    try {
      final resolved = await _resolveBasePath(basePath);
      if (resolved == null) return [];
      final List<dynamic> result = await _channel.invokeMethod('listDirectory', {
        'basePath': resolved,
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
    final resolved = await _resolveBasePath(basePath);
    if (resolved == null) throw Exception('No SAF tree URI available');
    final result = await _channel.invokeMethod('readFile', {
      'basePath': resolved,
      'relativePath': relativePath,
    });
    return result as String;
  }

  @override
  Future<void> writeFile(String basePath, String relativePath, String content) async {
    final resolved = await _resolveBasePath(basePath);
    if (resolved == null) throw Exception('No SAF tree URI available');
    await _channel.invokeMethod('writeFile', {
      'basePath': resolved,
      'relativePath': relativePath,
      'content': content,
    });
  }

  @override
  Future<void> createDirectory(String basePath, String relativePath) async {
    final resolved = await _resolveBasePath(basePath);
    if (resolved == null) throw Exception('No SAF tree URI available');
    await _channel.invokeMethod('createDirectory', {
      'basePath': resolved,
      'relativePath': relativePath,
    });
  }

  @override
  Future<void> deleteEntry(String basePath, String relativePath) async {
    final resolved = await _resolveBasePath(basePath);
    if (resolved == null) throw Exception('No SAF tree URI available');
    await _channel.invokeMethod('deleteEntry', {
      'basePath': resolved,
      'relativePath': relativePath,
    });
  }

  @override
  Future<void> renameEntry(String basePath, String oldRelativePath, String newName) async {
    final resolved = await _resolveBasePath(basePath);
    if (resolved == null) throw Exception('No SAF tree URI available');
    await _channel.invokeMethod('renameEntry', {
      'basePath': resolved,
      'oldRelativePath': oldRelativePath,
      'newName': newName,
    });
  }

  @override
  String formatPath(String basePath) {
    // SAF URIs are opaque — show a friendly label instead
    return 'SAF folder selected';
  }
}
