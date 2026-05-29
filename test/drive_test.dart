import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:filen_dart/api.dart';
import 'package:filen_dart/cache.dart';
import 'package:filen_dart/crypto.dart';
import 'package:filen_dart/drive.dart';

void main() {
  late FilenApi api;
  late FilenCrypto crypto;
  late FilenCache cache;
  late FilenDrive drive;
  late String masterKey;

  setUp(() async {
    masterKey = 'test-master-key-for-drive-tests0';
    crypto = FilenCrypto();
    cache = FilenCache();
  });

  group('resolvePath', () {
    test('resolves root path', () async {
      final mockClient = MockClient((request) async {
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
      });

      api = FilenApi(client: mockClient);
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root-uuid';
      drive.masterKeys = [masterKey];

      final result = await drive.resolvePath('/');
      expect(result['type'], equals('folder'));
      expect(result['uuid'], equals('root-uuid'));
      expect(result['path'], equals('/'));
    });

    test('throws when not logged in', () async {
      final mockClient = MockClient((request) async {
        return http.Response('{}', 200);
      });

      api = FilenApi(client: mockClient);
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = '';
      drive.masterKeys = [masterKey];

      expect(
        () => drive.resolvePath('/test'),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('Not logged in'))),
      );
    });
  });

  group('mutations', () {
    test('moveItem calls correct endpoint for file', () async {
      String? capturedEndpoint;
      Map<String, dynamic>? capturedBody;

      final mockClient = MockClient((request) async {
        capturedEndpoint = request.url.path;
        capturedBody = json.decode(request.body);
        return http.Response(
            json.encode({'status': true, 'data': {}}), 200);
      });

      api = FilenApi(client: mockClient);
      api.apiKey = 'test';
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root';
      drive.masterKeys = [masterKey];

      await drive.moveItem('file-uuid', 'dest-uuid', 'file');
      expect(capturedEndpoint, equals('/v3/file/move'));
      expect(capturedBody!['uuid'], equals('file-uuid'));
      expect(capturedBody!['to'], equals('dest-uuid'));
    });

    test('moveItem calls correct endpoint for folder', () async {
      String? capturedEndpoint;

      final mockClient = MockClient((request) async {
        capturedEndpoint = request.url.path;
        return http.Response(
            json.encode({'status': true, 'data': {}}), 200);
      });

      api = FilenApi(client: mockClient);
      api.apiKey = 'test';
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root';
      drive.masterKeys = [masterKey];

      await drive.moveItem('folder-uuid', 'dest-uuid', 'folder');
      expect(capturedEndpoint, equals('/v3/dir/move'));
    });

    test('trashItem calls correct endpoint', () async {
      String? capturedEndpoint;

      final mockClient = MockClient((request) async {
        capturedEndpoint = request.url.path;
        return http.Response(
            json.encode({'status': true, 'data': {}}), 200);
      });

      api = FilenApi(client: mockClient);
      api.apiKey = 'test';
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root';
      drive.masterKeys = [masterKey];

      await drive.trashItem('file-uuid', 'file');
      expect(capturedEndpoint, equals('/v3/file/trash'));
    });

    test('deletePermanently calls correct endpoint', () async {
      String? capturedEndpoint;

      final mockClient = MockClient((request) async {
        capturedEndpoint = request.url.path;
        return http.Response(
            json.encode({'status': true, 'data': {}}), 200);
      });

      api = FilenApi(client: mockClient);
      api.apiKey = 'test';
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root';
      drive.masterKeys = [masterKey];

      await drive.deletePermanently('folder-uuid', 'folder');
      expect(capturedEndpoint, equals('/v3/dir/delete/permanent'));
    });
  });

  group('createFolderRecursive', () {
    test('returns root info for empty path', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
            json.encode({'status': true, 'data': {}}), 200);
      });

      api = FilenApi(client: mockClient);
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root-uuid';
      drive.masterKeys = [masterKey];

      final result = await drive.createFolderRecursive('/');
      expect(result['uuid'], equals('root-uuid'));
      expect(result['path'], equals('/'));
    });

    test('throws when not logged in', () async {
      final mockClient = MockClient((request) async {
        return http.Response('{}', 200);
      });

      api = FilenApi(client: mockClient);
      drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = '';
      drive.masterKeys = [masterKey];

      expect(
        () => drive.createFolderRecursive('/test'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
