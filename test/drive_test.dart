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

  // Build a drive backed by a request handler, sharing the test cache+crypto.
  FilenDrive buildDrive(Future<http.Response> Function(http.Request) handler) {
    api = FilenApi(client: MockClient(handler))..apiKey = 'test';
    drive = FilenDrive(api: api, crypto: crypto, cache: cache)
      ..baseFolderUUID = 'root-uuid'
      ..masterKeys = [masterKey]
      ..email = 'test@example.com';
    return drive;
  }

  http.Response ok(Map<String, dynamic> data) =>
      http.Response(json.encode({'status': true, 'data': data}), 200);

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
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('Not logged in'))),
      );
    });

    test('resolves a multi-segment path to a nested file', () async {
      final encFoo = await crypto.encryptMetadata002('Foo', masterKey);
      final encBar = await crypto.encryptMetadata002(
          json.encode({'name': 'bar.txt', 'size': 7}), masterKey);
      final d = buildDrive((request) async {
        final body = json.decode(request.body) as Map<String, dynamic>;
        if (request.url.path == '/v3/dir/content') {
          if (body['uuid'] == 'root-uuid') {
            return ok({
              'folders': [
                {'uuid': 'foo-uuid', 'name': encFoo, 'parent': 'root-uuid'}
              ],
              'uploads': []
            });
          }
          if (body['uuid'] == 'foo-uuid') {
            return ok({
              'folders': [],
              'uploads': [
                {'uuid': 'bar-uuid', 'metadata': encBar, 'parent': 'foo-uuid'}
              ]
            });
          }
        }
        return ok({'folders': [], 'uploads': []});
      });

      final r = await d.resolvePath('/Foo/bar.txt');
      expect(r['type'], equals('file'));
      expect(r['uuid'], equals('bar-uuid'));
      expect(r['path'], equals('/Foo/bar.txt'));
      expect(r['parent'], equals('foo-uuid'));
    });

    test('throws "Path not found" for a missing segment', () async {
      final d =
          buildDrive((request) async => ok({'folders': [], 'uploads': []}));
      await expectLater(
        () => d.resolvePath('/Missing'),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('not found'))),
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
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
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
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
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
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
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
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
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
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
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

  group('mutations (cache + ordering)', () {
    test('moveItem clears the parent before mutating and invalidates caches',
        () async {
      final now = DateTime.now();
      cache.folderCache['src-parent'] =
          CacheEntry(items: const [], timestamp: now);
      cache.fileCache['src-parent'] =
          CacheEntry(items: const [], timestamp: now);
      cache.folderCache['dest-uuid'] =
          CacheEntry(items: const [], timestamp: now);
      cache.pathCache['/x'] = {'uuid': 'x'};

      final calls = <String>[];
      final d = buildDrive((request) async {
        calls.add(request.url.path);
        if (request.url.path == '/v3/file') return ok({'parent': 'src-parent'});
        return ok({});
      });

      await d.moveItem('file-1', 'dest-uuid', 'file');
      expect(cache.folderCache.containsKey('src-parent'), isFalse);
      expect(cache.fileCache.containsKey('src-parent'), isFalse);
      expect(
          cache.folderCache.containsKey('dest-uuid'), isFalse); // invalidated
      expect(cache.pathCache, isEmpty); // clearPathCache
      // The parent lookup (/v3/file) happens before the move mutation.
      expect(
          calls.indexOf('/v3/file'), lessThan(calls.indexOf('/v3/file/move')));
    });

    test('trashItem posts the uuid and clears the path cache', () async {
      cache.pathCache['/x'] = {'uuid': 'x'};
      Map<String, dynamic>? trashBody;
      final d = buildDrive((request) async {
        if (request.url.path == '/v3/file') return ok({'parent': 'p'});
        if (request.url.path == '/v3/file/trash') {
          trashBody = json.decode(request.body);
          return ok({});
        }
        return ok({});
      });

      await d.trashItem('file-1', 'file');
      expect(trashBody!['uuid'], equals('file-1'));
      expect(cache.pathCache, isEmpty);
    });

    test('restoreItem hits the restore endpoint and invalidates root',
        () async {
      cache.folderCache['root-uuid'] =
          CacheEntry(items: const [], timestamp: DateTime.now());
      String? path;
      final d = buildDrive((request) async {
        path = request.url.path;
        return ok({});
      });

      await d.restoreItem('file-1', 'file');
      expect(path, equals('/v3/file/restore'));
      expect(cache.folderCache.containsKey('root-uuid'), isFalse);
    });

    test('renameItem (folder) sends an encrypted name and a name hash',
        () async {
      Map<String, dynamic>? renameBody;
      final d = buildDrive((request) async {
        if (request.url.path == '/v3/dir') return ok({'parent': 'p'});
        if (request.url.path == '/v3/dir/rename') {
          renameBody = json.decode(request.body);
          return ok({});
        }
        return ok({});
      });

      await d.renameItem('dir-1', 'NewName', 'folder');
      expect(renameBody!['uuid'], equals('dir-1'));
      expect((renameBody!['name'] as String).startsWith('002'), isTrue);
      expect(renameBody!['nameHashed'], isNotEmpty);
    });

    test('renameItem (file) re-encrypts metadata with the new name', () async {
      const fileKey = 'abcdefghijklmnopqrstuvwxyz123456';
      final encMeta = await crypto.encryptMetadata002(
          json.encode({'name': 'old.txt', 'key': fileKey, 'size': 3}),
          masterKey);
      Map<String, dynamic>? renameBody;
      final d = buildDrive((request) async {
        if (request.url.path == '/v3/file') {
          return ok({'parent': 'p', 'metadata': encMeta});
        }
        if (request.url.path == '/v3/file/rename') {
          renameBody = json.decode(request.body);
          return ok({});
        }
        return ok({});
      });

      await d.renameItem('file-1', 'new.txt', 'file');
      expect(renameBody!['uuid'], equals('file-1'));
      final decMeta = json.decode(
          await crypto.decryptMetadata002(renameBody!['metadata'], masterKey));
      expect(decMeta['name'], equals('new.txt'));
      expect(renameBody!['nameHashed'], isNotEmpty);
    });

    test('checkFileExists returns the server flag and false on error',
        () async {
      var d = buildDrive((request) async {
        if (request.url.path == '/v3/file/exists') return ok({'exists': true});
        return ok({});
      });
      expect(await d.checkFileExists('parent', 'a.txt'), isTrue);

      d = buildDrive((request) async =>
          http.Response(json.encode({'status': false, 'message': 'x'}), 200));
      expect(await d.checkFileExists('parent', 'a.txt'), isFalse);
    });
  });

  group('trash, tree, find, search', () {
    test('getTrashContent merges folders+files and falls back to [Encrypted]',
        () async {
      final encSub = await crypto.encryptMetadata002('sub', masterKey);
      final encFile = await crypto.encryptMetadata002(
          json.encode({'name': 'a.txt', 'size': 10}), masterKey);
      final d = buildDrive((request) async {
        if (request.url.path == '/v3/dir/content') {
          return ok({
            'folders': [
              {'uuid': 'f1', 'name': encSub, 'parent': 'p', 'timestamp': 1},
              {'uuid': 'f2', 'name': 'garbage', 'parent': 'p', 'timestamp': 2},
            ],
            'uploads': [
              {
                'uuid': 'u1',
                'metadata': encFile,
                'parent': 'p',
                'timestamp': 3
              },
            ],
          });
        }
        return ok({});
      });

      final items = await d.getTrashContent();
      expect(items.where((i) => i['type'] == 'folder').length, equals(2));
      expect(items.firstWhere((i) => i['uuid'] == 'f1')['name'], equals('sub'));
      expect(items.firstWhere((i) => i['uuid'] == 'f2')['name'],
          equals('[Encrypted]'));
      final file = items.firstWhere((i) => i['type'] == 'file');
      expect(file['name'], equals('a.txt'));
      expect(file['size'], equals(10));
    });

    test('fetchAndParseTree builds adjacency and skips deleted items',
        () async {
      final encSub = await crypto.encryptMetadata002('sub', masterKey);
      final encGone = await crypto.encryptMetadata002('gone', masterKey);
      final encReport = await crypto.encryptMetadata002(
          json.encode({'name': 'report.pdf', 'size': 9}), masterKey);
      final d = buildDrive((request) async => http.Response(
          json.encode({
            'status': true,
            'data': {
              'folders': [
                {'uuid': 'sub-uuid', 'name': encSub, 'parent': 'root-uuid'},
                {
                  'uuid': 'del-uuid',
                  'name': encGone,
                  'parent': 'root-uuid',
                  'deleted': true
                },
              ],
              'files': [
                {
                  'uuid': 'rep-uuid',
                  'metadata': encReport,
                  'parent': 'sub-uuid'
                }
              ],
            }
          }),
          200));

      final adj = await d.fetchAndParseTree('root-uuid');
      final rootChildren = adj['root-uuid']!.map((e) => e['name']).toList();
      expect(rootChildren, contains('sub'));
      expect(rootChildren, isNot(contains('gone'))); // deleted skipped
      final report = adj['sub-uuid']!.single;
      expect(report['name'], equals('report.pdf'));
      expect(report['size'], equals(9));
    });

    test('findFiles matches a glob and reconstructs the full path', () async {
      final encSub = await crypto.encryptMetadata002('sub', masterKey);
      final encReport = await crypto.encryptMetadata002(
          json.encode({'name': 'report.pdf', 'size': 5}), masterKey);
      final encNote = await crypto.encryptMetadata002(
          json.encode({'name': 'note.txt', 'size': 2}), masterKey);
      final d = buildDrive((request) async {
        if (request.url.path == '/v3/dir/tree') {
          return http.Response(
              json.encode({
                'status': true,
                'data': {
                  'folders': [
                    {'uuid': 'sub-uuid', 'name': encSub, 'parent': 'root-uuid'}
                  ],
                  'files': [
                    {
                      'uuid': 'rep',
                      'metadata': encReport,
                      'parent': 'sub-uuid'
                    },
                    {'uuid': 'not', 'metadata': encNote, 'parent': 'root-uuid'},
                  ],
                }
              }),
              200);
        }
        return ok({}); // resolvePath('/') uses the no-network root branch
      });

      final results = await d.findFiles('/', '*.pdf');
      expect(results.length, equals(1));
      expect(results.single['name'], equals('report.pdf'));
      expect(results.single['fullPath'], equals('/sub/report.pdf'));
    });

    test('search wraps findFiles and returns files only', () async {
      final encReport = await crypto.encryptMetadata002(
          json.encode({'name': 'report.pdf', 'size': 5}), masterKey);
      final d = buildDrive((request) async {
        if (request.url.path == '/v3/dir/tree') {
          return http.Response(
              json.encode({
                'status': true,
                'data': {
                  'folders': [],
                  'files': [
                    {
                      'uuid': 'rep',
                      'metadata': encReport,
                      'parent': 'root-uuid'
                    }
                  ],
                }
              }),
              200);
        }
        return ok({});
      });

      final res = await d.search('report');
      expect(res['folders'], isEmpty);
      expect(res['files']!.single['name'], equals('report.pdf'));
    });
  });
}
