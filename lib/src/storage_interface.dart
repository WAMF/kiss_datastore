import 'dart:typed_data';
import 'package:kiss_datastore/kiss_datastore.dart';

/// Abstract interface for storage backends
abstract class StorageInterface {
  /// Store a datastore item at the given path
  Future<void> storeItem(String path, DatastoreItem item);

  /// Store raw data at the given path
  Future<void> storeRawData(String path, Uint8List data);

  /// Retrieve a datastore item from the given path
  Future<DatastoreItem?> getItem(String path);

  /// Retrieve raw data from the given path
  Future<Uint8List?> getRawData(String path);

  /// Check if an item exists at the given path
  Future<bool> exists(String path);

  /// Delete both item and raw data at the given path
  Future<void> delete(String path);

  /// Clear all data from storage
  Future<void> clear();

  /// Get all stored paths
  Future<List<String>> getPaths();
}
