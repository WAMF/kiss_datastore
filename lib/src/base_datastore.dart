import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kiss_datastore/kiss_datastore.dart';
import 'storage_interface.dart';

abstract class BaseDatastore extends Datastore {
  final StorageInterface storage;
  final String _providerName;

  bool get uploadSlowMode => false;
  Duration get uploadSlowModeDelay => const Duration(milliseconds: 100);
  int get uploadSlowModeChunkSize => 1024;

  BaseDatastore(this.storage, this._providerName);

  @override
  String get providerName => _providerName;

  @override
  Future<bool> exists(String path) async {
    return await storage.exists(path);
  }

  @override
  Future<void> delete(String path) async {
    await storage.delete(path);
  }

  @override
  Future<Uri> getDownloadLink(String path, {DateTime? expires}) async {
    final item = await storage.getItem(path);
    if (item == null) {
      throw Exception('Item not found at path: $path');
    }
    return item.uri;
  }

  @override
  Future<DatastoreItem> get(String path) async {
    final item = await storage.getItem(path);
    if (item == null) {
      throw Exception('Item not found at path: $path');
    }
    return item;
  }

  @override
  Upload<DatastoreItem> putData(
    String path,
    Uint8List data, {
    String? contentType,
    String? contentEncoding,
    String? contentLanguage,
    String? cacheControl,
    void Function(DatastoreItem)? onComplete,
  }) {
    final context = _UploadContext(
      path: path,
      data: data,
      contentType: contentType,
      contentEncoding: contentEncoding,
      contentLanguage: contentLanguage,
      cacheControl: cacheControl,
      onComplete: onComplete,
      providerName: providerName,
    );

    return _createUpload(context);
  }

  Upload<DatastoreItem> _createUpload(_UploadContext context) {
    final completer = Completer<DatastoreItem>();
    final progressController = StreamController<int>();
    final identifier =
        '${providerName}_upload_${DateTime.now().millisecondsSinceEpoch}_${context.path.hashCode}';

    final uri = _generateUri(context.path);
    final item = DatastoreItem(
      uri: uri,
      contentType: context.contentType ?? 'application/octet-stream',
      uploadDate: DateTime.now(),
      providerName: context.providerName,
      prividerIdentifier: identifier,
      extra: {
        if (context.contentEncoding != null)
          'contentEncoding': context.contentEncoding,
        if (context.contentLanguage != null)
          'contentLanguage': context.contentLanguage,
        if (context.cacheControl != null) 'cacheControl': context.cacheControl,
      },
    );

    final uploadState = _UploadState(
      cancelled: false,
      paused: false,
      uploadTimer: null,
    );

    void cancel() =>
        _cancelUpload(context, uploadState, progressController, completer);
    void pause() => _pauseUpload(uploadState);
    void resume() => _resumeUpload(
      context,
      item,
      uploadState,
      progressController,
      completer,
    );

    final upload = Upload<DatastoreItem>(
      null,
      progressController.stream,
      completer.future,
      cancel,
      pause,
      resume,
      identifier,
      context.contentType,
    );

    _startUpload(context, item, uploadState, progressController, completer);
    return upload;
  }

  /// Generate URI for the stored item - can be overridden by subclasses
  Uri _generateUri(String path) {
    // Replace invalid scheme characters with hyphens
    final validScheme = providerName.replaceAll('_', '-');
    return Uri.parse('$validScheme://storage/$path');
  }

  void _startUpload(
    _UploadContext context,
    DatastoreItem item,
    _UploadState state,
    StreamController<int> progressController,
    Completer<DatastoreItem> completer,
  ) {
    if (state.cancelled) return;

    if (uploadSlowMode) {
      _simulateSlowUpload(context, item, state, progressController, completer);
    } else {
      _completeUpload(context, item, progressController, completer);
    }
  }

  void _simulateSlowUpload(
    _UploadContext context,
    DatastoreItem item,
    _UploadState state,
    StreamController<int> progressController,
    Completer<DatastoreItem> completer,
  ) {
    int uploaded = 0;
    final totalSize = context.data.length;

    void uploadChunk() {
      if (state.cancelled || state.paused) return;

      final remaining = totalSize - uploaded;
      final chunkSize = remaining < uploadSlowModeChunkSize
          ? remaining
          : uploadSlowModeChunkSize;

      uploaded += chunkSize;
      progressController.add(uploaded);

      if (uploaded >= totalSize) {
        _completeUpload(context, item, progressController, completer);
      } else {
        state.uploadTimer = Timer(uploadSlowModeDelay, uploadChunk);
      }
    }

    uploadChunk();
  }

  void _completeUpload(
    _UploadContext context,
    DatastoreItem item,
    StreamController<int> progressController,
    Completer<DatastoreItem> completer,
  ) {
    storage.storeItem(context.path, item);
    storage.storeRawData(context.path, context.data);

    progressController.add(context.data.length);
    progressController.close();

    context.onComplete?.call(item);
    completer.complete(item);
  }

  void _cancelUpload(
    _UploadContext context,
    _UploadState state,
    StreamController<int> progressController,
    Completer<DatastoreItem> completer,
  ) {
    state.cancelled = true;
    state.uploadTimer?.cancel();
    progressController.close();
    if (!completer.isCompleted) {
      completer.completeError('Upload cancelled');
    }
  }

  void _pauseUpload(_UploadState state) {
    state.paused = true;
    state.uploadTimer?.cancel();
  }

  void _resumeUpload(
    _UploadContext context,
    DatastoreItem item,
    _UploadState state,
    StreamController<int> progressController,
    Completer<DatastoreItem> completer,
  ) {
    if (!state.cancelled && state.paused) {
      state.paused = false;
      _startUpload(context, item, state, progressController, completer);
    }
  }

  /// Clear all data from storage
  Future<void> clear() async {
    await storage.clear();
  }

  /// Get all stored paths
  Future<List<String>> getPaths() async {
    return await storage.getPaths();
  }

  /// Get raw data for a path (used by HTTP client) - should be overridden
  Future<Uint8List?> getRawData(String path) async {
    return await storage.getRawData(path);
  }

  /// Get datastore item for a path (used by HTTP client) - should be overridden
  Future<DatastoreItem?> getDatastoreItem(String path) async {
    return await storage.getItem(path);
  }

  /// Create a 404 HTTP response
  static Future<DatastoreHttpClientResponse> _create404Response() async {
    final response = DatastoreHttpClientResponse();
    response.statusCode = 404;
    response.reasonPhrase = 'Not Found';
    response.headers.set('content-type', 'text/plain');
    response.headers.set('content-length', '9');
    response._setData(utf8.encode('Not Found'));
    return response;
  }

  /// Create a success HTTP response with data and headers
  static Future<DatastoreHttpClientResponse> _createSuccessResponse(
    Uint8List data,
    DatastoreItem item,
  ) async {
    final response = DatastoreHttpClientResponse();
    response.statusCode = 200;
    response.reasonPhrase = 'OK';
    response.headers.set('content-type', item.contentType);
    response.headers.set('content-length', data.length.toString());
    response.headers.set('last-modified', HttpDate.format(item.uploadDate));

    // Add extra headers from item
    if (item.extra['contentEncoding'] != null) {
      response.headers.set('content-encoding', item.extra['contentEncoding']);
    }
    if (item.extra['contentLanguage'] != null) {
      response.headers.set('content-language', item.extra['contentLanguage']);
    }
    if (item.extra['cacheControl'] != null) {
      response.headers.set('cache-control', item.extra['cacheControl']);
    }

    response._setData(data);
    return response;
  }
}

class _UploadContext {
  final String path;
  final Uint8List data;
  final String? contentType;
  final String? contentEncoding;
  final String? contentLanguage;
  final String? cacheControl;
  final void Function(DatastoreItem)? onComplete;
  final String providerName;

  _UploadContext({
    required this.path,
    required this.data,
    this.contentType,
    this.contentEncoding,
    this.contentLanguage,
    this.cacheControl,
    this.onComplete,
    required this.providerName,
  });
}

class _UploadState {
  bool cancelled;
  bool paused;
  Timer? uploadTimer;

  _UploadState({
    required this.cancelled,
    required this.paused,
    required this.uploadTimer,
  });
}

/// Simple HTTP response for datastore HTTP clients
class DatastoreHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int statusCode = 200;

  @override
  String reasonPhrase = 'OK';

  @override
  final HttpHeaders headers = DatastoreHttpHeaders();

  late final Stream<List<int>> _stream;

  void _setData(Uint8List data) {
    _stream = Stream.fromIterable([data]);
  }

  // Essential HttpClientResponse properties
  @override
  List<RedirectInfo> get redirects => [];
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  X509Certificate? get certificate => null;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  int get contentLength => -1;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  List<Cookie> get cookies => [];

  // Unsupported operations
  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) => throw UnsupportedError('Redirect not supported');
  @override
  Future<Socket> detachSocket() =>
      throw UnsupportedError('DetachSocket not supported');

  // Stream implementation - delegate to internal stream
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

/// Simple HTTP headers for datastore HTTP clients
class DatastoreHttpHeaders implements HttpHeaders {
  final Map<String, String> _headers = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _headers[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => _headers[name.toLowerCase()];

  // Basic required implementations
  @override
  List<String>? operator [](String name) =>
      _headers[name.toLowerCase()]?.let((v) => [v]);
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      set(name, value, preserveHeaderCase: preserveHeaderCase);
  @override
  void remove(String name, Object value) => _headers.remove(name.toLowerCase());
  @override
  void removeAll(String name) => _headers.remove(name.toLowerCase());
  @override
  void clear() => _headers.clear();
  @override
  void forEach(void Function(String, List<String>) action) =>
      _headers.forEach((k, v) => action(k, [v]));
  @override
  void noFolding(String name) {} // No-op

  // Common properties with minimal implementation
  @override
  bool get chunkedTransferEncoding => false;
  @override
  set chunkedTransferEncoding(bool value) {}
  @override
  int get contentLength =>
      int.tryParse(_headers['content-length'] ?? '-1') ?? -1;
  @override
  set contentLength(int contentLength) => set('content-length', contentLength);
  @override
  ContentType? get contentType =>
      _headers['content-type']?.let(ContentType.parse);
  @override
  set contentType(ContentType? contentType) => contentType != null
      ? set('content-type', contentType.toString())
      : removeAll('content-type');

  // Unused properties - minimal implementations
  @override
  DateTime? get date => null;
  @override
  set date(DateTime? date) {}
  @override
  DateTime? get expires => null;
  @override
  set expires(DateTime? expires) {}
  @override
  String? get host => null;
  @override
  set host(String? host) {}
  @override
  DateTime? get ifModifiedSince => null;
  @override
  set ifModifiedSince(DateTime? ifModifiedSince) {}
  @override
  bool get persistentConnection => false;
  @override
  set persistentConnection(bool persistentConnection) {}
  @override
  int? get port => null;
  @override
  set port(int? port) {}
}

extension _LetExtension<T> on T {
  R let<R>(R Function(T) transform) => transform(this);
}

/// Base HTTP client for datastore implementations
abstract class DatastoreHttpClient {
  /// Parse URL and handle HTTP request
  Future<HttpClientResponse> get(Uri url) async {
    final pathSegments = url.pathSegments;

    // Extract provider type and identifier from URL
    if (pathSegments.isEmpty) {
      return BaseDatastore._create404Response();
    }

    final providerType = pathSegments[0];
    if (pathSegments.length < 3) {
      return BaseDatastore._create404Response();
    }

    final identifier = pathSegments[1];
    final dataPath = pathSegments.skip(2).join('/');

    // Get the datastore instance
    final instance = getDatastoreInstance(providerType, identifier);
    if (instance == null) {
      return BaseDatastore._create404Response();
    }

    final rawData = await instance.getRawData(dataPath);
    final item = await instance.getDatastoreItem(dataPath);

    if (rawData == null || item == null) {
      return BaseDatastore._create404Response();
    }

    return BaseDatastore._createSuccessResponse(rawData, item);
  }

  /// Get datastore instance by provider type and identifier
  BaseDatastore? getDatastoreInstance(String providerType, String identifier);

  /// Make any HTTP request (delegates to GET for simplicity)
  Future<HttpClientResponse> request(String method, Uri url) => get(url);
}
