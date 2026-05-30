import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:filen_dart/api.dart';
import 'package:filen_dart/cache.dart';
import 'package:filen_dart/crypto.dart';
import 'package:filen_dart/drive.dart';
import 'package:filen_dart/upload.dart';

void main() {
  late FilenApi api;
  late FilenCrypto crypto;
  late FilenCache cache;
  late FilenDrive drive;
  late FilenUpload uploader;
  late String masterKey;

  group('ChunkUploadException', () {
    test('toString includes all fields', () {
      final ex = ChunkUploadException(
        'test error',
        fileUuid: 'uuid-123',
        uploadKey: 'key-456',
        lastSuccessfulChunk: 3,
      );
      expect(ex.toString(), contains('uuid-123'));
      expect(ex.toString(), contains('key-456'));
      expect(ex.toString(), contains('3'));
      expect(ex.toString(), contains('test error'));
    });

    test('stores original error', () {
      final original = Exception('network failure');
      final ex = ChunkUploadException(
        'chunk failed',
        fileUuid: 'uuid',
        uploadKey: 'key',
        lastSuccessfulChunk: 0,
        originalError: original,
      );
      expect(ex.originalError, equals(original));
    });
  });

  group('FilenUpload', () {
    setUp(() {
      masterKey = 'test-master-key-for-upload-tests0';
      crypto = FilenCrypto(random: Random(42));
    });

    test('uploadFileChunked handles empty file', () async {
      final requests = <String>[];

      final mockClient = MockClient((request) async {
        requests.add(request.url.path);
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
      });

      api = FilenApi(client: mockClient);
      api.apiKey = 'test-key';
      cache = FilenCache();
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root-uuid';
      drive.masterKeys = [masterKey];
      drive.email = 'test@example.com';
      uploader =
          FilenUpload(api: api, crypto: crypto, cache: cache, drive: drive);

      // Create empty temp file
      final tempFile =
          File('${Directory.systemTemp.path}/filen_test_empty.txt');
      await tempFile.writeAsString('');

      try {
        final result =
            await uploader.uploadFileChunked(tempFile, 'parent-uuid');
        expect(result['uuid'], isNotEmpty);
        expect(result['hash'], equals(''));
        expect(result['size'], equals('0'));
        // Should have called /v3/upload/empty
        expect(requests, contains('/v3/upload/empty'));
      } finally {
        if (tempFile.existsSync()) tempFile.deleteSync();
      }
    });

    test('uploadFileChunked calls progress callback', () async {
      final progressCalls = <List<int>>[];

      final mockClient = MockClient((request) async {
        // Accept all uploads
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
      });

      api = FilenApi(client: mockClient);
      api.apiKey = 'test-key';
      cache = FilenCache();
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root-uuid';
      drive.masterKeys = [masterKey];
      drive.email = 'test@example.com';
      uploader =
          FilenUpload(api: api, crypto: crypto, cache: cache, drive: drive);

      // Create small temp file (< 1MB = single chunk)
      final tempFile =
          File('${Directory.systemTemp.path}/filen_test_progress.txt');
      await tempFile.writeAsString('Hello World');

      try {
        await uploader.uploadFileChunked(
          tempFile,
          'parent-uuid',
          onProgress: (current, total, bytesUp, totalBytes) {
            progressCalls.add([current, total, bytesUp, totalBytes]);
          },
        );

        expect(progressCalls, isNotEmpty);
        // Single chunk file: 1/1
        expect(progressCalls.last[0], equals(1));
        expect(progressCalls.last[1], equals(1));
      } finally {
        if (tempFile.existsSync()) tempFile.deleteSync();
      }
    });

    test('uploadFileChunked fires onUploadStart callback', () async {
      String? capturedUuid;
      String? capturedKey;

      final mockClient = MockClient((request) async {
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
      });

      api = FilenApi(client: mockClient);
      api.apiKey = 'test-key';
      cache = FilenCache();
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root-uuid';
      drive.masterKeys = [masterKey];
      drive.email = 'test@example.com';
      uploader =
          FilenUpload(api: api, crypto: crypto, cache: cache, drive: drive);

      final tempFile =
          File('${Directory.systemTemp.path}/filen_test_start.txt');
      await tempFile.writeAsString('test content');

      try {
        await uploader.uploadFileChunked(
          tempFile,
          'parent-uuid',
          onUploadStart: (uuid, key) {
            capturedUuid = uuid;
            capturedKey = key;
          },
          onProgress: (_, __, ___, ____) {},
        );

        expect(capturedUuid, isNotNull);
        expect(capturedUuid, isNotEmpty);
        expect(capturedKey, isNotNull);
        expect(capturedKey, isNotEmpty);
      } finally {
        if (tempFile.existsSync()) tempFile.deleteSync();
      }
    });

    test('uploadBytes handles empty data', () async {
      final requests = <String>[];

      final mockClient = MockClient((request) async {
        requests.add(request.url.path);
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
      });

      api = FilenApi(client: mockClient);
      api.apiKey = 'test-key';
      cache = FilenCache();
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root-uuid';
      drive.masterKeys = [masterKey];
      drive.email = 'test@example.com';
      uploader =
          FilenUpload(api: api, crypto: crypto, cache: cache, drive: drive);

      await uploader.uploadBytes(Uint8List(0), 'empty.txt', 'parent-uuid');

      expect(requests, contains('/v3/upload/empty'));
    });
  });
}
