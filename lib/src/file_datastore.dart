import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kiss_datastore/kiss_datastore.dart';
import 'storage_interface.dart';
import 'base_datastore.dart';

/// File-based datastore implementation
class FileDatastore extends BaseDatastore {
  final String basePath;
  final bool _uploadSlowMode;
  final Duration _uploadSlowModeDelay;
  final int _uploadSlowModeChunkSize;
  late final FileHttpClient _httpClient;

  FileDatastore(
    this.basePath, {
    bool uploadSlowMode = false,
    Duration uploadSlowModeDelay = const Duration(milliseconds: 100),
    int uploadSlowModeChunkSize = 1024,
  }) : _uploadSlowMode = uploadSlowMode,
       _uploadSlowModeDelay = uploadSlowModeDelay,
       _uploadSlowModeChunkSize = uploadSlowModeChunkSize,
       super(FileStorage(basePath), 'file_datastore') {
    _httpClient = FileHttpClient._(this);
  }

  @override
  bool get uploadSlowMode => _uploadSlowMode;

  @override
  Duration get uploadSlowModeDelay => _uploadSlowModeDelay;

  @override
  int get uploadSlowModeChunkSize => _uploadSlowModeChunkSize;

  /// HTTP client for this datastore instance
  FileHttpClient get httpClient => _httpClient;
}

/// HTTP client for file datastore
class FileHttpClient extends DatastoreHttpClient {
  final FileDatastore _datastore;

  FileHttpClient._(this._datastore);

  @override
  BaseDatastore? getDatastoreInstance(String providerType, String identifier) {
    if (providerType != 'file_datastore') {
      return null;
    }
    final basePath = Uri.decodeComponent(identifier);
    // Only return this instance if the base path matches
    if (_datastore.basePath == basePath) {
      return _datastore;
    }
    return null;
  }
}

class FileStorage implements StorageInterface {
  final Directory _baseDirectory;
  final Directory _itemsDirectory;
  final Directory _dataDirectory;

  FileStorage(String basePath)
    : _baseDirectory = Directory(basePath),
      _itemsDirectory = Directory('$basePath/items'),
      _dataDirectory = Directory('$basePath/data') {
    _ensureDirectoriesExist();
  }

  void _ensureDirectoriesExist() {
    if (!_baseDirectory.existsSync()) {
      _baseDirectory.createSync(recursive: true);
    }
    if (!_itemsDirectory.existsSync()) {
      _itemsDirectory.createSync(recursive: true);
    }
    if (!_dataDirectory.existsSync()) {
      _dataDirectory.createSync(recursive: true);
    }
  }

  String _getItemPath(String path) {
    final sanitizedPath = _sanitizePath(path);
    return '${_itemsDirectory.path}/$sanitizedPath.json';
  }

  String _getDataPath(String path) {
    final sanitizedPath = _sanitizePath(path);
    return '${_dataDirectory.path}/$sanitizedPath.dat';
  }

  String _sanitizePath(String path) {
    // Replace path separators and other problematic characters
    return path
        .replaceAll('/', '_')
        .replaceAll('\\', '_')
        .replaceAll(':', '_')
        .replaceAll('?', '_')
        .replaceAll('*', '_')
        .replaceAll('<', '_')
        .replaceAll('>', '_')
        .replaceAll('|', '_')
        .replaceAll('"', '_');
  }

  @override
  Future<void> storeItem(String path, DatastoreItem item) async {
    final file = File(_getItemPath(path));
    final json = jsonEncode(item.toJson());
    await file.writeAsString(json);
  }

  @override
  Future<void> storeRawData(String path, Uint8List data) async {
    final file = File(_getDataPath(path));
    await file.writeAsBytes(data);
  }

  @override
  Future<DatastoreItem?> getItem(String path) async {
    final file = File(_getItemPath(path));
    if (!await file.exists()) {
      return null;
    }

    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return DatastoreItem.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  @override
  Future<Uint8List?> getRawData(String path) async {
    final file = File(_getDataPath(path));
    if (!await file.exists()) {
      return null;
    }

    try {
      return await file.readAsBytes();
    } catch (e) {
      return null;
    }
  }

  @override
  Future<bool> exists(String path) async {
    final itemFile = File(_getItemPath(path));
    final dataFile = File(_getDataPath(path));
    return await itemFile.exists() && await dataFile.exists();
  }

  @override
  Future<void> delete(String path) async {
    final itemFile = File(_getItemPath(path));
    final dataFile = File(_getDataPath(path));

    if (await itemFile.exists()) {
      await itemFile.delete();
    }
    if (await dataFile.exists()) {
      await dataFile.delete();
    }
  }

  @override
  Future<void> clear() async {
    // Delete all files in both directories
    await for (final entity in _itemsDirectory.list()) {
      if (entity is File) {
        await entity.delete();
      }
    }

    await for (final entity in _dataDirectory.list()) {
      if (entity is File) {
        await entity.delete();
      }
    }
  }

  @override
  Future<List<String>> getPaths() async {
    final paths = <String>[];

    await for (final entity in _itemsDirectory.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        final filename = entity.uri.pathSegments.last;
        final pathWithoutExtension = filename.substring(
          0,
          filename.length - 5,
        ); // Remove .json
        final originalPath = _unsanitizePath(pathWithoutExtension);
        paths.add(originalPath);
      }
    }

    return paths;
  }

  String _unsanitizePath(String sanitizedPath) {
    // This is a basic reverse transformation - in a real implementation,
    // you might want to store the original path mapping
    return sanitizedPath.replaceAll('_', '/');
  }
}
