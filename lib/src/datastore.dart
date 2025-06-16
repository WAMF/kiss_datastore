import 'dart:typed_data';

class Upload<T> {
  Upload(
    this.providerTask,
    this.progress,
    this.result,
    this.cancel,
    this.pause,
    this.resume,
    this.identifier,
    this.contentType,
  );
  final dynamic providerTask;
  final Stream<int> progress;
  final Future<T> result;
  final String identifier;
  final String? contentType;
  late final void Function() cancel;
  late final void Function() pause;
  late final void Function() resume;
}

class DatastoreItem {
  DatastoreItem({
    required this.uri,
    required this.contentType,
    required this.uploadDate,
    required this.providerName,
    this.prividerIdentifier,
  });

  factory DatastoreItem.fromJson(Map<String, dynamic> json) {
    final epoch = json['uploadDate'] as int? ?? 0;
    return DatastoreItem(
      uri: Uri.parse(json['uri'] as String),
      contentType: json['contentType'] as String,
      uploadDate: DateTime.fromMillisecondsSinceEpoch(epoch),
      prividerIdentifier: json['prividerIdentifier'] as String?,
      providerName: json['providerName'] as String,
    );
  }
  final Uri uri;
  final String contentType;
  final DateTime uploadDate;
  final String? prividerIdentifier;
  final String providerName;

  Map<String, dynamic> toJson() {
    return {
      'uri': uri.toString(),
      'contentType': contentType,
      'uploadDate': uploadDate.millisecondsSinceEpoch,
      'prividerIdentifier': prividerIdentifier,
      'providerName': providerName,
    };
  }
}

abstract class Datastore {
  String get providerName;
  Upload<DatastoreItem> putData(
    String path,
    Uint8List data, {
    String? contentType,
    String? contentEncoding,
    String? contentLanguage,
    String? cacheControl,
    void Function(DatastoreItem) onComplete,
  });

  Future<bool> exists(String path);

  Future<void> delete(String path);

  Future<Uri> getDownloadLink(String path);

  Future<Uint8List?> get(String path);
}
