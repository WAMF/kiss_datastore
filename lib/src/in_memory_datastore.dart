import 'dart:async';
import 'dart:typed_data';

import 'package:kiss_datastore/kiss_datastore.dart';
import 'package:kiss_datastore/src/base_datastore.dart';
import 'package:kiss_datastore/src/storage_interface.dart';

/// In-memory storage implementation
class InMemoryStorage implements StorageInterface {
  final Map<String, DatastoreItem> _items = {};
  final Map<String, Uint8List> _rawData = {};

  @override
  Future<void> storeItem(String path, DatastoreItem item) async {
    _items[path] = item;
  }

  @override
  Future<void> storeRawData(String path, Uint8List data) async {
    _rawData[path] = data;
  }

  @override
  Future<DatastoreItem?> getItem(String path) async {
    return _items[path];
  }

  @override
  Future<Uint8List?> getRawData(String path) async {
    return _rawData[path];
  }

  @override
  Future<bool> exists(String path) async {
    return _items.containsKey(path);
  }

  @override
  Future<void> delete(String path) async {
    _items.remove(path);
    _rawData.remove(path);
  }

  @override
  Future<void> clear() async {
    _items.clear();
    _rawData.clear();
  }

  @override
  Future<List<String>> getPaths() async {
    return _items.keys.toList();
  }
}

/// In-memory datastore implementation
class InMemoryDatastore extends BaseDatastore {
  final String _instanceId;
  final bool _uploadSlowMode;
  final Duration _uploadSlowModeDelay;
  final int _uploadSlowModeChunkSize;
  late final InMemoryHttpClient _httpClient;

  InMemoryDatastore([
    String instanceId = 'default',
    bool uploadSlowMode = false,
    Duration uploadSlowModeDelay = const Duration(milliseconds: 100),
    int uploadSlowModeChunkSize = 1024,
  ]) : _instanceId = instanceId,
       _uploadSlowMode = uploadSlowMode,
       _uploadSlowModeDelay = uploadSlowModeDelay,
       _uploadSlowModeChunkSize = uploadSlowModeChunkSize,
       super(InMemoryStorage(), 'in_memory_$instanceId') {
    _httpClient = InMemoryHttpClient._(this);
  }

  @override
  bool get uploadSlowMode => _uploadSlowMode;

  @override
  Duration get uploadSlowModeDelay => _uploadSlowModeDelay;

  @override
  int get uploadSlowModeChunkSize => _uploadSlowModeChunkSize;

  /// HTTP client for this datastore instance
  InMemoryHttpClient get httpClient => _httpClient;
}

/// HTTP client for in-memory datastore
class InMemoryHttpClient extends DatastoreHttpClient {
  final InMemoryDatastore _datastore;

  InMemoryHttpClient._(this._datastore);

  @override
  BaseDatastore? getDatastoreInstance(String providerType, String identifier) {
    if (providerType != 'in_memory') {
      return null;
    }
    // Only return this instance if the identifier matches
    if (_datastore._instanceId == identifier) {
      return _datastore;
    }
    return null;
  }
}
