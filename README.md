# Kiss Datastore

A simple, abstract datastore interface for Dart with an in-memory implementation for testing and development.

## Features

- **Abstract Datastore Interface** - Clean API for file storage operations
- **InMemoryDatastore** - Full in-memory implementation for testing
- **Upload Progress Tracking** - Real-time progress streams with pause/resume/cancel
- **Slow Mode Simulation** - Configurable upload chunking for realistic testing
- **HTTP Client** - Built-in HTTP server to serve stored data
- **Multiple Instances** - Named datastore instances for isolation

## Usage

### Basic Operations

```dart
import 'package:kiss_datastore/src/in_memory_datastore.dart';

// Create datastore instance
final datastore = InMemoryDatastore('my-instance');

// Upload data
final data = utf8.encode('Hello, World!');
final upload = datastore.putData(
  'hello.txt', 
  data, 
  contentType: 'text/plain',
);

// Monitor progress
upload.progress.listen((bytesUploaded) {
  print('Uploaded: $bytesUploaded bytes');
});

// Wait for completion
final item = await upload.result;
print('Stored at: ${item.uri}');

// Check if file exists
final exists = await datastore.exists('hello.txt');

// Retrieve data
final retrievedItem = await datastore.get('hello.txt');

// Delete data
await datastore.delete('hello.txt');
```

### HTTP Client

```dart
// Get HTTP client
final client = InMemoryDatastore.httpClient;

// Fetch data via HTTP
final response = await client.get(
  Uri.parse('http://localhost:8080/in_memory/my-instance/hello.txt')
);

// Read response
final responseData = <int>[];
await response.listen(responseData.addAll).asFuture();
print('Content: ${utf8.decode(responseData)}');
```

### Slow Mode for Testing

```dart
// Enable slow upload simulation
InMemoryDatastore.uploadSlowMode = true;
InMemoryDatastore.uploadSlowModeDelay = Duration(milliseconds: 100);
InMemoryDatastore.uploadSlowModeChunkSize = 1024;

// Upload will now be chunked with delays
final upload = datastore.putData('large-file.bin', largeData);

// Control upload
upload.pause();   // Pause upload
upload.resume();  // Resume upload  
upload.cancel();  // Cancel upload
```

## Testing

Run tests with:

```bash
dart test
```

The test suite covers:
- Basic CRUD operations
- Upload progress and control
- Slow mode simulation  
- HTTP client functionality
- Multiple instance isolation
- Error handling

## Interface

The `Datastore` abstract class defines:

- `putData()` - Upload data with progress tracking
- `get()` - Retrieve stored item metadata
- `exists()` - Check if item exists
- `delete()` - Remove stored item
- `getDownloadLink()` - Get download URL

Perfect for:
- **Testing** cloud storage implementations
- **Development** without external dependencies
- **Prototyping** storage-based applications
- **CI/CD** pipelines requiring storage simulation
