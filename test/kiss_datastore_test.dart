import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kiss_datastore/src/base_datastore.dart';
import 'package:test/test.dart';
import 'package:kiss_datastore/kiss_datastore.dart';

void main() {
  group('Datastore Implementations', () {
    group('InMemoryDatastore', () {
      runInMemoryDatastoreTests();
    });

    group('FileDatastore', () {
      runFileDatastoreTests();
    });
  });
}

void runInMemoryDatastoreTests() {
  group('Fast Mode', () {
    late InMemoryDatastore datastore;

    setUp(() async {
      datastore = InMemoryDatastore('test', false);
      // Clear any existing data
      await datastore.clear();
    });

    runDatastoreTests(() => datastore);
    runHttpClientTests(
      () => datastore,
      () => datastore.httpClient,
      (String instanceId, String path) =>
          Uri.parse('http://localhost:8080/in_memory/test/$path'),
    );
  });

  group('Slow Mode', () {
    late InMemoryDatastore datastore;

    setUp(() async {
      datastore = InMemoryDatastore(
        'test-slow',
        true,
        const Duration(milliseconds: 10),
        50,
      );
      // Clear any existing data
      await datastore.clear();
    });

    runDatastoreTests(() => datastore);
    runHttpClientTests(
      () => datastore,
      () => datastore.httpClient,
      (String instanceId, String path) =>
          Uri.parse('http://localhost:8080/in_memory/test-slow/$path'),
    );
  });
}

void runFileDatastoreTests() {
  group('Fast Mode', () {
    const testDir = './test_storage_fast';
    late FileDatastore datastore;

    setUp(() async {
      datastore = FileDatastore(testDir, uploadSlowMode: false);
      // Clear any existing data
      await datastore.clear();
    });

    tearDown(() async {
      final dir = Directory(testDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    runDatastoreTests(() => datastore);
    runHttpClientTests(
      () => datastore,
      () => datastore.httpClient,
      (String instanceId, String path) => Uri.parse(
        'http://localhost:8080/file_datastore/${Uri.encodeComponent(testDir)}/$path',
      ),
    );
  });

  group('Slow Mode', () {
    const testDir = './test_storage_slow';
    late FileDatastore datastore;

    setUp(() async {
      datastore = FileDatastore(
        testDir,
        uploadSlowMode: true,
        uploadSlowModeDelay: const Duration(milliseconds: 10),
        uploadSlowModeChunkSize: 50,
      );
      // Clear any existing data
      await datastore.clear();
    });

    tearDown(() async {
      final dir = Directory(testDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    runDatastoreTests(() => datastore);
    runHttpClientTests(
      () => datastore,
      () => datastore.httpClient,
      (String instanceId, String path) => Uri.parse(
        'http://localhost:8080/file_datastore/${Uri.encodeComponent(testDir)}/$path',
      ),
    );
  });
}

/// Generic test suite that can test any Datastore implementation
void runDatastoreTests(Datastore Function() getDatastore) {
  group('Basic Operations', () {
    test('should store and retrieve data', () async {
      final datastore = getDatastore();
      final data = utf8.encode('Hello, World!');
      final upload = datastore.putData(
        'test.txt',
        data,
        contentType: 'text/plain',
      );

      final item = await upload.result;
      expect(item.contentType, equals('text/plain'));
      expect(item.providerName, isNotNull);
      expect(item.uri.toString(), contains('test.txt'));

      // Test exists
      expect(await datastore.exists('test.txt'), isTrue);
      expect(await datastore.exists('nonexistent.txt'), isFalse);

      // Test get
      final retrievedItem = await datastore.get('test.txt');
      expect(retrievedItem.contentType, equals('text/plain'));
      expect(retrievedItem.uri, equals(item.uri));

      // Test download link
      final downloadUri = await datastore.getDownloadLink('test.txt');
      expect(downloadUri, equals(item.uri));
    });

    test('should delete data', () async {
      final datastore = getDatastore();
      final data = utf8.encode('Test data');
      await datastore.putData('delete-me.txt', data).result;

      expect(await datastore.exists('delete-me.txt'), isTrue);

      await datastore.delete('delete-me.txt');

      expect(await datastore.exists('delete-me.txt'), isFalse);
    });

    test('should handle content metadata', () async {
      final datastore = getDatastore();
      final data = utf8.encode('Test content');
      final upload = datastore.putData(
        'test.txt',
        data,
        contentType: 'text/plain',
        contentEncoding: 'gzip',
        contentLanguage: 'en',
        cacheControl: 'max-age=3600',
      );

      final item = await upload.result;
      expect(item.contentType, equals('text/plain'));
      expect(item.extra['contentEncoding'], equals('gzip'));
      expect(item.extra['contentLanguage'], equals('en'));
      expect(item.extra['cacheControl'], equals('max-age=3600'));
    });

    test('should throw when getting non-existent data', () async {
      final datastore = getDatastore();
      expect(() => datastore.get('nonexistent.txt'), throwsException);
      expect(
        () => datastore.getDownloadLink('nonexistent.txt'),
        throwsException,
      );
    });

    test('should handle multiple files', () async {
      final datastore = getDatastore();
      final data1 = utf8.encode('File 1 content');
      final data2 = utf8.encode('File 2 content');

      await datastore.putData('file1.txt', data1).result;
      await datastore.putData('file2.txt', data2).result;

      expect(await datastore.exists('file1.txt'), isTrue);
      expect(await datastore.exists('file2.txt'), isTrue);

      final item1 = await datastore.get('file1.txt');
      final item2 = await datastore.get('file2.txt');

      expect(item1.uri, isNot(equals(item2.uri)));
    });
  });

  group('Upload Progress', () {
    test('should report upload progress', () async {
      final datastore = getDatastore();
      final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final upload = datastore.putData('progress-test.bin', data);

      final progressValues = <int>[];
      final progressCompleter = Completer<void>();

      upload.progress.listen(
        progressValues.add,
        onDone: () => progressCompleter.complete(),
      );

      await upload.result;
      await progressCompleter.future;

      expect(progressValues, isNotEmpty);
      expect(progressValues.last, equals(data.length));
    });
  });

  group('Upload Control', () {
    test('should handle upload cancellation', () async {
      final datastore = getDatastore();

      // Only test cancellation on slow mode datastores
      if (datastore is BaseDatastore && !datastore.uploadSlowMode) {
        return; // Skip for fast mode
      }

      final data = Uint8List.fromList(List.generate(5000, (i) => i % 256));
      final upload = datastore.putData('cancel-test.bin', data);

      // Cancel after a short delay
      Future.delayed(Duration(milliseconds: 50), () => upload.cancel());

      expect(upload.result, throwsA(isA<String>()));
    });

    test('should handle upload pause and resume', () async {
      final datastore = getDatastore();

      // Only test pause/resume on slow mode datastores
      if (datastore is BaseDatastore && !datastore.uploadSlowMode) {
        return; // Skip for fast mode
      }

      final data = Uint8List.fromList(List.generate(500, (i) => i % 256));
      final upload = datastore.putData('pause-test.bin', data);

      final progressValues = <int>[];
      upload.progress.listen(progressValues.add);

      // Pause after a short delay
      Future.delayed(Duration(milliseconds: 25), () {
        upload.pause();
        // Resume after another delay
        Future.delayed(Duration(milliseconds: 100), () => upload.resume());
      });

      final item = await upload.result;
      expect(item, isNotNull);
      expect(await datastore.exists('pause-test.bin'), isTrue);
    });
  });

  group('Upload Callback', () {
    test('should call onComplete callback', () async {
      final datastore = getDatastore();
      final data = utf8.encode('Callback test');
      bool callbackCalled = false;
      dynamic callbackItem;

      final upload = datastore.putData(
        'callback-test.txt',
        data,
        onComplete: (item) {
          callbackCalled = true;
          callbackItem = item;
        },
      );

      await upload.result;

      expect(callbackCalled, isTrue);
      expect(callbackItem, isNotNull);
      expect(callbackItem.contentType, equals('application/octet-stream'));
    });
  });

  group('Upload Properties', () {
    test('should provide upload properties', () async {
      final datastore = getDatastore();
      final data = utf8.encode('Properties test');
      final upload = datastore.putData(
        'props-test.txt',
        data,
        contentType: 'text/plain',
      );

      expect(upload.identifier, isNotNull);
      expect(upload.contentType, equals('text/plain'));

      await upload.result; // Complete the upload
    });
  });

  group('BaseDatastore Features', () {
    test('should clear all data', () async {
      final datastore = getDatastore();
      final data1 = utf8.encode('File 1');
      final data2 = utf8.encode('File 2');

      await datastore.putData('file1.txt', data1).result;
      await datastore.putData('file2.txt', data2).result;

      expect(await datastore.exists('file1.txt'), isTrue);
      expect(await datastore.exists('file2.txt'), isTrue);

      if (datastore is BaseDatastore) {
        await datastore.clear();
      }

      expect(await datastore.exists('file1.txt'), isFalse);
      expect(await datastore.exists('file2.txt'), isFalse);
    });

    test('should list all paths', () async {
      final datastore = getDatastore();
      final data = utf8.encode('Test data');

      await datastore.putData('file1.txt', data).result;
      await datastore.putData('file2.txt', data).result;
      await datastore.putData('subdir/file3.txt', data).result;

      if (datastore is BaseDatastore) {
        final paths = await datastore.getPaths();

        expect(paths, contains('file1.txt'));
        expect(paths, contains('file2.txt'));
        expect(paths, contains('subdir/file3.txt'));
        expect(paths.length, equals(3));
      }
    });
  });
}

/// HTTP Client tests (only for datastores that support it)
void runHttpClientTests(
  Datastore Function() getDatastore,
  dynamic Function() getHttpClient,
  Uri Function(String instanceId, String path) getHttpUri,
) {
  group('HTTP Client', () {
    test('should serve stored data via HTTP client', () async {
      final datastore = getDatastore();
      final data = utf8.encode('HTTP test data');
      await datastore
          .putData('http-test.txt', data, contentType: 'text/plain')
          .result;

      final client = getHttpClient();
      final uri = getHttpUri('test', 'http-test.txt');

      final response = await client.get(uri);

      expect(response.statusCode, equals(200));
      expect(response.headers.value('content-type'), equals('text/plain'));
      expect(
        response.headers.value('content-length'),
        equals(data.length.toString()),
      );

      // Read response data
      final responseData = <int>[];
      await response.listen(responseData.addAll).asFuture();
      expect(responseData, equals(data));
    });

    test('should return 404 for non-existent data', () async {
      final client = getHttpClient();
      final uri = getHttpUri('test', 'nonexistent.txt');

      final response = await client.get(uri);

      expect(response.statusCode, equals(404));
      expect(response.reasonPhrase, equals('Not Found'));
      expect(response.headers.value('content-type'), equals('text/plain'));

      final responseData = <int>[];
      await response.listen(responseData.addAll).asFuture();
      expect(utf8.decode(responseData), equals('Not Found'));
    });

    test('should return 404 for invalid URL format', () async {
      final client = getHttpClient();
      final uri = Uri.parse('http://localhost:8080/invalid/path');

      final response = await client.get(uri);
      expect(response.statusCode, equals(404));
    });

    test('should include metadata in HTTP headers', () async {
      final datastore = getDatastore();
      final data = utf8.encode('Header test data');
      await datastore
          .putData(
            'header-test.txt',
            data,
            contentType: 'text/plain',
            contentEncoding: 'gzip',
            contentLanguage: 'en',
            cacheControl: 'max-age=3600',
          )
          .result;

      final client = getHttpClient();
      final uri = getHttpUri('test', 'header-test.txt');

      final response = await client.get(uri);

      expect(response.headers.value('content-type'), equals('text/plain'));
      expect(response.headers.value('content-encoding'), equals('gzip'));
      expect(response.headers.value('content-language'), equals('en'));
      expect(response.headers.value('cache-control'), equals('max-age=3600'));
    });
  });
}
