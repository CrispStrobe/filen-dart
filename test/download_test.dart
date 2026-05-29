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
import 'package:filen_dart/download.dart';

void main() {
  late FilenCrypto crypto;
  late String masterKey;

  setUp(() {
    masterKey = 'test-master-key-for-download-test';
    crypto = FilenCrypto(random: Random(42));
  });

  group('FilenDownload', () {
    test('downloadFileBytes decrypts and returns bytes', () async {
      // 1. Encrypt test data with known key
      final testData = Uint8List.fromList(utf8.encode('Hello from Filen!'));
      final fileKey = 'abcdefghijklmnopqrstuvwxyz123456'; // 32 chars
      final fileKeyBytes = Uint8List.fromList(utf8.encode(fileKey));
      final encryptedChunk = await crypto.encryptData(testData, fileKeyBytes);

      // 2. Encrypt metadata with master key
      final metaJson = json.encode({
        'name': 'test.txt',
        'size': testData.length,
        'mime': 'text/plain',
        'key': fileKey,
        'hash': 'abc123',
        'lastModified': 1700000000000,
      });
      final encryptedMeta =
          await crypto.encryptMetadata002(metaJson, masterKey);

      // 3. Mock API: /v3/file returns metadata, egest returns encrypted chunk
      final mockClient = MockClient((request) async {
        final url = request.url.toString();

        if (url.contains('/v3/file')) {
          return http.Response(
              json.encode({
                'status': true,
                'data': {
                  'metadata': encryptedMeta,
                  'chunks': 1,
                  'region': 'eu',
                  'bucket': 'b1',
                  'uuid': 'file-uuid-123',
                }
              }),
              200);
        }

        if (url.contains('egest.filen.io')) {
          // Return encrypted chunk as raw bytes
          return http.Response.bytes(encryptedChunk, 200);
        }

        return http.Response('Not found', 404);
      });

      final api = FilenApi(client: mockClient);
      api.apiKey = 'test-key';
      final cache = FilenCache();
      final drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root';
      drive.masterKeys = [masterKey];
      drive.email = 'test@example.com';

      final downloader = FilenDownload(
          api: api, crypto: crypto, cache: cache, drive: drive);

      final result = await downloader.downloadFileBytes('file-uuid-123');

      expect(utf8.decode(result), equals('Hello from Filen!'));
    });

    test('downloadFileBytes calls progress callback', () async {
      final testData = Uint8List.fromList(utf8.encode('progress test'));
      final fileKey = 'abcdefghijklmnopqrstuvwxyz123456';
      final fileKeyBytes = Uint8List.fromList(utf8.encode(fileKey));
      final encryptedChunk = await crypto.encryptData(testData, fileKeyBytes);

      final metaJson = json.encode({
        'name': 'progress.txt',
        'size': testData.length,
        'mime': 'text/plain',
        'key': fileKey,
        'hash': '',
        'lastModified': 0,
      });
      final encryptedMeta =
          await crypto.encryptMetadata002(metaJson, masterKey);

      final mockClient = MockClient((request) async {
        if (request.url.toString().contains('/v3/file')) {
          return http.Response(
              json.encode({
                'status': true,
                'data': {
                  'metadata': encryptedMeta,
                  'chunks': 1,
                  'region': 'eu',
                  'bucket': 'b1',
                }
              }),
              200);
        }
        if (request.url.toString().contains('egest.filen.io')) {
          return http.Response.bytes(encryptedChunk, 200);
        }
        return http.Response('Not found', 404);
      });

      final api = FilenApi(client: mockClient);
      api.apiKey = 'test-key';
      final cache = FilenCache();
      final drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root';
      drive.masterKeys = [masterKey];
      drive.email = 'test@example.com';

      final downloader = FilenDownload(
          api: api, crypto: crypto, cache: cache, drive: drive);

      final progressCalls = <List<int>>[];
      await downloader.downloadFileBytes(
        'file-uuid-123',
        onProgress: (downloaded, total) {
          progressCalls.add([downloaded, total]);
        },
      );

      expect(progressCalls, isNotEmpty);
      expect(progressCalls.last[0], greaterThan(0));
    });

    test('downloadFile saves to disk and returns metadata', () async {
      final testData = Uint8List.fromList(utf8.encode('disk save test'));
      final fileKey = 'abcdefghijklmnopqrstuvwxyz123456';
      final fileKeyBytes = Uint8List.fromList(utf8.encode(fileKey));
      final encryptedChunk = await crypto.encryptData(testData, fileKeyBytes);

      final metaJson = json.encode({
        'name': 'saved.txt',
        'size': testData.length,
        'mime': 'text/plain',
        'key': fileKey,
        'hash': '',
        'lastModified': 1700000000000,
      });
      final encryptedMeta =
          await crypto.encryptMetadata002(metaJson, masterKey);

      final mockClient = MockClient((request) async {
        if (request.url.toString().contains('/v3/file')) {
          return http.Response(
              json.encode({
                'status': true,
                'data': {
                  'metadata': encryptedMeta,
                  'chunks': 1,
                  'region': 'eu',
                  'bucket': 'b1',
                }
              }),
              200);
        }
        if (request.url.toString().contains('egest.filen.io')) {
          return http.Response.bytes(encryptedChunk, 200);
        }
        return http.Response('Not found', 404);
      });

      final api = FilenApi(client: mockClient);
      api.apiKey = 'test-key';
      final cache = FilenCache();
      final drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root';
      drive.masterKeys = [masterKey];
      drive.email = 'test@example.com';

      final downloader = FilenDownload(
          api: api, crypto: crypto, cache: cache, drive: drive);

      final savePath =
          '${Directory.systemTemp.path}/filen_dl_test_${DateTime.now().millisecondsSinceEpoch}.txt';

      try {
        final result = await downloader.downloadFile('uuid-123',
            savePath: savePath);

        expect(result['filename'], equals('saved.txt'));
        expect(result['modificationTime'], equals(1700000000000));
        expect(File(savePath).existsSync(), isTrue);

        final content = await File(savePath).readAsString();
        expect(content, equals('disk save test'));
      } finally {
        final f = File(savePath);
        if (f.existsSync()) f.deleteSync();
      }
    });
  });
}
