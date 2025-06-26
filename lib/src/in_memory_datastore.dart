import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kiss_datastore/kiss_datastore.dart';

class InMemoryDatastore extends Datastore {
  final Map<String, DatastoreItem> _data = {};
  final Map<String, Uint8List> _rawData = {};
  static final Map<String, InMemoryDatastore> _instances = {};

  static bool uploadSlowMode = false;
  static Duration uploadSlowModeDelay = const Duration(milliseconds: 100);
  static int uploadSlowModeChunkSize = 1024;

  final String _instanceId;

  InMemoryDatastore._internal(this._instanceId);

  factory InMemoryDatastore([String instanceId = 'default']) {
    return _instances.putIfAbsent(
      instanceId,
      () => InMemoryDatastore._internal(instanceId),
    );
  }

  @override
  String get providerName => 'in_memory';

  @override
  Future<bool> exists(String path) async {
    return _data.containsKey(path);
  }

  @override
  Future<void> delete(String path) async {
    _data.remove(path);
    _rawData.remove(path);
  }

  @override
  Future<Uri> getDownloadLink(String path, {DateTime? expires}) async {
    final item = _data[path];
    if (item == null) {
      throw Exception('Item not found at path: $path');
    }
    return item.uri;
  }

  @override
  Future<DatastoreItem> get(String path) async {
    final item = _data[path];
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
      instanceId: _instanceId,
      providerName: providerName,
    );

    return _createUpload(context);
  }

  Upload<DatastoreItem> _createUpload(_UploadContext context) {
    final completer = Completer<DatastoreItem>();
    final progressController = StreamController<int>();
    final identifier =
        'in_memory_upload_${DateTime.now().millisecondsSinceEpoch}_${context.path.hashCode}';

    final uri = Uri.parse(
      'http://localhost:8080/in_memory/${context.instanceId}/${context.path}',
    );
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
    _data[context.path] = item;
    _rawData[context.path] = context.data;

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

  /// Get raw data for a path (used by HTTP client)
  Uint8List? getRawData(String path) {
    return _rawData[path];
  }

  /// Get datastore item for a path (used by HTTP client)
  DatastoreItem? getItem(String path) {
    return _data[path];
  }

  /// Get datastore instance by ID (used by HTTP client)
  static InMemoryDatastore? getInstance(String instanceId) {
    return _instances[instanceId];
  }

  /// Static HTTP client that serves data from InMemoryDatastore instances
  static InMemoryHttpClient get httpClient => InMemoryHttpClient._();

  static Future<_InMemoryHttpClientResponse> _create404Response() async {
    final response = _InMemoryHttpClientResponse();
    response.statusCode = 404;
    response.reasonPhrase = 'Not Found';
    response.headers.set('content-type', 'text/plain');
    response.headers.set('content-length', '9');
    response._setData(utf8.encode('Not Found'));
    return response;
  }

  static Future<_InMemoryHttpClientResponse> _createSuccessResponse(
    Uint8List data,
    DatastoreItem item,
  ) async {
    final response = _InMemoryHttpClientResponse();
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

/// Simple HTTP response for in-memory datastore
class _InMemoryHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int statusCode = 200;

  @override
  String reasonPhrase = 'OK';

  @override
  final HttpHeaders headers = _InMemoryHttpHeaders();

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

/// Simple HTTP headers for in-memory datastore
class _InMemoryHttpHeaders implements HttpHeaders {
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

class _UploadContext {
  final String path;
  final Uint8List data;
  final String? contentType;
  final String? contentEncoding;
  final String? contentLanguage;
  final String? cacheControl;
  final void Function(DatastoreItem)? onComplete;
  final String instanceId;
  final String providerName;

  _UploadContext({
    required this.path,
    required this.data,
    this.contentType,
    this.contentEncoding,
    this.contentLanguage,
    this.cacheControl,
    this.onComplete,
    required this.instanceId,
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

/// Simple HTTP client for in-memory datastore
class InMemoryHttpClient {
  InMemoryHttpClient._();

  /// Make a GET request to the in-memory datastore
  Future<HttpClientResponse> get(Uri url) async {
    final pathSegments = url.pathSegments;

    // Expected format: /in_memory/{instanceId}/{path...}
    if (pathSegments.length < 3 || pathSegments[0] != 'in_memory') {
      return InMemoryDatastore._create404Response();
    }

    final instanceId = pathSegments[1];
    final dataPath = pathSegments.skip(2).join('/');

    final instance = InMemoryDatastore.getInstance(instanceId);
    if (instance == null) {
      return InMemoryDatastore._create404Response();
    }

    final rawData = instance.getRawData(dataPath);
    final item = instance.getItem(dataPath);

    if (rawData == null || item == null) {
      return InMemoryDatastore._create404Response();
    }

    return InMemoryDatastore._createSuccessResponse(rawData, item);
  }

  /// Make any HTTP request (delegates to GET for simplicity)
  Future<HttpClientResponse> request(String method, Uri url) => get(url);
}
