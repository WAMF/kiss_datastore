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

This is the base interface package, included are two reference implementations.
** Concrete implemenations for different providers are provided in other packages. **

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

This is also a file based version if local persistance is needed.

### Slow Mode Configuration

```dart
// Configure slow mode per instance
final slowDatastore = InMemoryDatastore(
  'test-instance',
  true,                                    // Enable slow mode
  const Duration(milliseconds: 50),        // Delay between chunks
  1024,                                    // Chunk size in bytes
);

// Or for FileDatastore
final slowFileStore = FileDatastore(
  './test_storage',
  uploadSlowMode: true,
  uploadSlowModeDelay: const Duration(milliseconds: 100),
  uploadSlowModeChunkSize: 512,
);

// Upload will now be chunked with delays
final upload = slowDatastore.putData('large-file.bin', largeData);

// Control upload (only works in slow mode)
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
- Basic CRUD operations for both implementations
- Upload progress and control
- Slow mode simulation  
- HTTP client functionality
- Instance isolation
- File system operations
- Error handling

