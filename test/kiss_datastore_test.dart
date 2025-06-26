import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:kiss_datastore/src/in_memory_datastore.dart';

void main() {
  group('InMemoryDatastore', () {
    late InMemoryDatastore datastore;

    setUp(() {
      datastore = InMemoryDatastore('test');
      // Reset slow mode for each test
      InMemoryDatastore.uploadSlowMode = false;
    });

    group('Basic Operations', () {
      test('should store and retrieve data', () async {
        final data = utf8.encode('Hello, World!');
        final upload = datastore.putData(
          'test.txt',
          data,
          contentType: 'text/plain',
        );

        final item = await upload.result;
        expect(item.contentType, equals('text/plain'));
        expect(item.providerName, equals('in_memory'));
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

        // Test HTTP client retrieval
        final client = InMemoryDatastore.httpClient;
        final response = await client.get(item.uri);

        expect(response.statusCode, equals(200));
        expect(response.headers.value('content-type'), equals('text/plain'));
        expect(
          response.headers.value('content-length'),
          equals(data.length.toString()),
        );

        // Verify the actual data matches what we stored
        final responseData = <int>[];
        await response.listen(responseData.addAll).asFuture();
        expect(responseData, equals(data));
        expect(utf8.decode(responseData), equals('Hello, World!'));
      });

      test('should handle multiple instances', () async {
        final datastore1 = InMemoryDatastore('instance1');
        final datastore2 = InMemoryDatastore('instance2');

        final data1 = utf8.encode('Data for instance 1');
        final data2 = utf8.encode('Data for instance 2');

        await datastore1.putData('file.txt', data1).result;
        await datastore2.putData('file.txt', data2).result;

        expect(await datastore1.exists('file.txt'), isTrue);
        expect(await datastore2.exists('file.txt'), isTrue);

        // Same instance should return same object
        expect(InMemoryDatastore('instance1'), same(datastore1));
      });

      test('should delete data', () async {
        final data = utf8.encode('Test data');
        await datastore.putData('delete-me.txt', data).result;

        expect(await datastore.exists('delete-me.txt'), isTrue);

        await datastore.delete('delete-me.txt');

        expect(await datastore.exists('delete-me.txt'), isFalse);
      });

      test('should handle content metadata', () async {
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
        expect(() => datastore.get('nonexistent.txt'), throwsException);
        expect(
          () => datastore.getDownloadLink('nonexistent.txt'),
          throwsException,
        );
      });
    });

    group('Upload Progress', () {
      test(
        'should report progress immediately when slow mode is off',
        () async {
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
        },
      );

      test('should handle upload cancellation', () async {
        InMemoryDatastore.uploadSlowMode = true;
        InMemoryDatastore.uploadSlowModeDelay = Duration(milliseconds: 100);

        final data = Uint8List.fromList(List.generate(5000, (i) => i % 256));
        final upload = datastore.putData('cancel-test.bin', data);

        // Cancel after a short delay
        Future.delayed(Duration(milliseconds: 50), () => upload.cancel());

        expect(upload.result, throwsA(isA<String>()));
      });

      test('should handle upload pause and resume', () async {
        InMemoryDatastore.uploadSlowMode = true;
        InMemoryDatastore.uploadSlowModeDelay = Duration(milliseconds: 50);
        InMemoryDatastore.uploadSlowModeChunkSize = 100;

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

    group('Slow Mode', () {
      test('should simulate slow upload with progress updates', () async {
        InMemoryDatastore.uploadSlowMode = true;
        InMemoryDatastore.uploadSlowModeDelay = Duration(milliseconds: 10);
        InMemoryDatastore.uploadSlowModeChunkSize = 100;

        final data = Uint8List.fromList(List.generate(350, (i) => i % 256));
        final upload = datastore.putData('slow-test.bin', data);

        final progressValues = <int>[];
        upload.progress.listen(progressValues.add);

        final startTime = DateTime.now();
        await upload.result;
        final duration = DateTime.now().difference(startTime);

        // Should take some time due to slow mode
        expect(duration.inMilliseconds, greaterThan(20));

        // Should have multiple progress updates
        expect(progressValues.length, greaterThan(1));
        expect(progressValues.last, equals(data.length));

        // Progress should be incremental
        for (int i = 1; i < progressValues.length; i++) {
          expect(
            progressValues[i],
            greaterThanOrEqualTo(progressValues[i - 1]),
          );
        }
      });
    });

    group('HTTP Client', () {
      test('should serve stored data via HTTP client', () async {
        final data = utf8.encode('HTTP test data');
        await datastore
            .putData('http-test.txt', data, contentType: 'text/plain')
            .result;

        final client = InMemoryDatastore.httpClient;
        final uri = Uri.parse(
          'http://localhost:8080/in_memory/test/http-test.txt',
        );

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
        final client = InMemoryDatastore.httpClient;
        final uri = Uri.parse(
          'http://localhost:8080/in_memory/test/nonexistent.txt',
        );

        final response = await client.get(uri);

        expect(response.statusCode, equals(404));
        expect(response.reasonPhrase, equals('Not Found'));
        expect(response.headers.value('content-type'), equals('text/plain'));

        final responseData = <int>[];
        await response.listen(responseData.addAll).asFuture();
        expect(utf8.decode(responseData), equals('Not Found'));
      });

      test('should return 404 for invalid URL format', () async {
        final client = InMemoryDatastore.httpClient;
        final uri = Uri.parse('http://localhost:8080/invalid/path');

        final response = await client.get(uri);
        expect(response.statusCode, equals(404));
      });

      test('should return 404 for non-existent instance', () async {
        final client = InMemoryDatastore.httpClient;
        final uri = Uri.parse(
          'http://localhost:8080/in_memory/nonexistent-instance/file.txt',
        );

        final response = await client.get(uri);
        expect(response.statusCode, equals(404));
      });

      test('should handle request method parameter', () async {
        final data = utf8.encode('Method test data');
        await datastore.putData('method-test.txt', data).result;

        final client = InMemoryDatastore.httpClient;
        final uri = Uri.parse(
          'http://localhost:8080/in_memory/test/method-test.txt',
        );

        final response = await client.request('GET', uri);
        expect(response.statusCode, equals(200));

        // POST should also work (delegates to GET)
        final response2 = await client.request('POST', uri);
        expect(response2.statusCode, equals(200));
      });

      test('should include metadata in HTTP headers', () async {
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

        final client = InMemoryDatastore.httpClient;
        final uri = Uri.parse(
          'http://localhost:8080/in_memory/test/header-test.txt',
        );

        final response = await client.get(uri);

        expect(response.headers.value('content-type'), equals('text/plain'));
        expect(response.headers.value('content-encoding'), equals('gzip'));
        expect(response.headers.value('content-language'), equals('en'));
        expect(response.headers.value('cache-control'), equals('max-age=3600'));
      });
    });

    group('Upload Callback', () {
      test('should call onComplete callback', () async {
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
        final data = utf8.encode('Properties test');
        final upload = datastore.putData(
          'props-test.txt',
          data,
          contentType: 'text/plain',
        );

        expect(upload.identifier, isNotNull);
        expect(upload.identifier, contains('in_memory_upload_'));
        expect(upload.contentType, equals('text/plain'));
        expect(
          upload.providerTask,
          isNull,
        ); // Not used in memory implementation

        await upload.result; // Complete the upload
      });
    });
  });
}
