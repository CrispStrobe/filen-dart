import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:filen_dart/api.dart';
import 'package:filen_dart/cache.dart';
import 'package:filen_dart/crypto.dart';

void main() {
  group('CacheEntry', () {
    test('stores items and timestamp', () {
      final now = DateTime.now();
      final entry = CacheEntry(items: ['a', 'b'], timestamp: now);
      expect(entry.items, equals(['a', 'b']));
      expect(entry.timestamp, equals(now));
    });
  });

  group('FilenCache', () {
    late FilenCache cache;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2024, 1, 1, 12, 0);
      cache = FilenCache(clock: () => fakeNow);
    });

    test('cache duration is 10 minutes', () {
      expect(FilenCache.cacheDuration, equals(Duration(minutes: 10)));
    });

    test('invalidate removes folder and file cache', () {
      cache.folderCache['uuid-1'] = CacheEntry(
        items: [
          {'name': 'test'}
        ],
        timestamp: fakeNow,
      );
      cache.fileCache['uuid-1'] = CacheEntry(
        items: [
          {'name': 'file.txt'}
        ],
        timestamp: fakeNow,
      );

      cache.invalidate('uuid-1');
      expect(cache.folderCache.containsKey('uuid-1'), isFalse);
      expect(cache.fileCache.containsKey('uuid-1'), isFalse);
    });

    test('invalidate does not affect other UUIDs', () {
      cache.folderCache['uuid-1'] = CacheEntry(
        items: [
          {'name': 'test'}
        ],
        timestamp: fakeNow,
      );
      cache.folderCache['uuid-2'] = CacheEntry(
        items: [
          {'name': 'other'}
        ],
        timestamp: fakeNow,
      );

      cache.invalidate('uuid-1');
      expect(cache.folderCache.containsKey('uuid-1'), isFalse);
      expect(cache.folderCache.containsKey('uuid-2'), isTrue);
    });

    test('clearPathCache clears all path entries', () {
      cache.pathCache['/docs'] = {'uuid': 'uuid-1', 'type': 'folder'};
      cache.pathCache['/docs/sub'] = {'uuid': 'uuid-2', 'type': 'folder'};

      cache.clearPathCache();
      expect(cache.pathCache, isEmpty);
    });

    test('pathCache stores and retrieves entries', () {
      final entry = {'uuid': 'uuid-1', 'type': 'folder', 'path': '/docs'};
      cache.pathCache['/docs'] = entry;

      expect(cache.pathCache['/docs'], equals(entry));
      expect(cache.pathCache['/other'], isNull);
    });

    test('invalidate is a no-op for an unknown uuid', () {
      cache.invalidate('no-such-uuid'); // must not throw
      expect(cache.folderCache, isEmpty);
      expect(cache.fileCache, isEmpty);
    });
  });

  group('FilenCache listing + TTL (mocked API)', () {
    const masterKey = 'test-master-key-for-cache-tests0';
    late FilenCrypto crypto;
    late DateTime fakeNow;

    setUp(() {
      crypto = FilenCrypto();
      fakeNow = DateTime(2024, 1, 1, 12, 0);
    });

    FilenApi failingApi() => FilenApi(
        client: MockClient((req) async =>
            throw StateError('no network expected: ${req.url}')));

    test('listFoldersAsync returns cached entries without hitting the network',
        () async {
      final cache = FilenCache(clock: () => fakeNow);
      cache.folderCache['fid'] = CacheEntry(items: [
        {'type': 'folder', 'name': 'cached', 'uuid': 'c1', 'size': 0}
      ], timestamp: fakeNow);

      final result = await cache.listFoldersAsync('fid',
          api: failingApi(), crypto: crypto, masterKeys: [masterKey]);
      expect(result.single['name'], equals('cached'));
    });

    test('listFoldersAsync fetches+decrypts+caches on a miss, then expires',
        () async {
      final cache = FilenCache(clock: () => fakeNow);
      final encName = await crypto.encryptMetadata002('Documents', masterKey);
      var hits = 0;
      final api = FilenApi(client: MockClient((req) async {
        hits++;
        return http.Response(
            json.encode({
              'status': true,
              'data': {
                'folders': [
                  {'uuid': 'f1', 'name': encName, 'parent': 'fid'}
                ]
              }
            }),
            200);
      }));

      final first = await cache.listFoldersAsync('fid',
          api: api, crypto: crypto, masterKeys: [masterKey], detailed: true);
      expect(first.single['name'], equals('Documents'));
      expect(hits, equals(1));
      expect(cache.folderCache.containsKey('fid'), isTrue);

      // Second call within the TTL is served from cache (no extra request).
      await cache.listFoldersAsync('fid',
          api: api, crypto: crypto, masterKeys: [masterKey]);
      expect(hits, equals(1));

      // Past the 10-minute TTL it re-fetches.
      fakeNow = fakeNow.add(const Duration(minutes: 11));
      await cache.listFoldersAsync('fid',
          api: api, crypto: crypto, masterKeys: [masterKey]);
      expect(hits, equals(2));
    });

    test('listFoldersAsync detailed=false projects to the summary keys',
        () async {
      final cache = FilenCache(clock: () => fakeNow);
      final encName = await crypto.encryptMetadata002('Docs', masterKey);
      final api = FilenApi(
          client: MockClient((req) async => http.Response(
              json.encode({
                'status': true,
                'data': {
                  'folders': [
                    {'uuid': 'f1', 'name': encName, 'parent': 'fid'}
                  ]
                }
              }),
              200)));
      final result = await cache.listFoldersAsync('fid',
          api: api, crypto: crypto, masterKeys: [masterKey]);
      expect(
          result.single.keys.toSet(), equals({'type', 'name', 'uuid', 'size'}));
    });

    test('listFolderFiles decrypts metadata and reports size', () async {
      final cache = FilenCache(clock: () => fakeNow);
      final encMeta = await crypto.encryptMetadata002(
          json.encode({'name': 'a.txt', 'size': 42, 'lastModified': 1}),
          masterKey);
      final api = FilenApi(
          client: MockClient((req) async => http.Response(
              json.encode({
                'status': true,
                'data': {
                  'uploads': [
                    {'uuid': 'u1', 'metadata': encMeta, 'parent': 'fid'}
                  ]
                }
              }),
              200)));
      final result = await cache.listFolderFiles('fid',
          api: api, crypto: crypto, masterKeys: [masterKey], detailed: true);
      expect(result.single['name'], equals('a.txt'));
      expect(result.single['size'], equals(42));
    });

    test('listing falls back to [Encrypted] when a name cannot be decrypted',
        () async {
      final cache = FilenCache(clock: () => fakeNow);
      final api = FilenApi(
          client: MockClient((req) async => http.Response(
              json.encode({
                'status': true,
                'data': {
                  'folders': [
                    {
                      'uuid': 'f1',
                      'name': 'undecryptable-garbage',
                      'parent': 'fid'
                    }
                  ]
                }
              }),
              200)));
      final result = await cache.listFoldersAsync('fid',
          api: api, crypto: crypto, masterKeys: [masterKey]);
      expect(result.single['name'], equals('[Encrypted]'));
    });

    test('clearParentCache (file) invalidates the resolved parent', () async {
      final cache = FilenCache(clock: () => fakeNow);
      cache.folderCache['parent-uuid'] =
          CacheEntry(items: const [], timestamp: fakeNow);
      cache.fileCache['parent-uuid'] =
          CacheEntry(items: const [], timestamp: fakeNow);
      final api = FilenApi(
          client: MockClient((req) async => http.Response(
              json.encode({
                'status': true,
                'data': {'parent': 'parent-uuid'}
              }),
              200)));

      await cache
          .clearParentCache('item-uuid', 'file', api, crypto, [masterKey]);
      expect(cache.folderCache.containsKey('parent-uuid'), isFalse);
      expect(cache.fileCache.containsKey('parent-uuid'), isFalse);
    });

    test('clearParentCache (folder) queries /v3/dir for the parent', () async {
      final cache = FilenCache(clock: () => fakeNow);
      cache.folderCache['grandparent'] =
          CacheEntry(items: const [], timestamp: fakeNow);
      String? hitPath;
      final api = FilenApi(client: MockClient((req) async {
        hitPath = req.url.path;
        return http.Response(
            json.encode({
              'status': true,
              'data': {'parent': 'grandparent'}
            }),
            200);
      }));

      await cache.clearParentCache('item', 'folder', api, crypto, [masterKey]);
      expect(hitPath, equals('/v3/dir'));
      expect(cache.folderCache.containsKey('grandparent'), isFalse);
    });

    test('clearParentCache swallows errors and leaves the cache intact',
        () async {
      final cache = FilenCache(clock: () => fakeNow);
      cache.folderCache['parent-uuid'] =
          CacheEntry(items: const [], timestamp: fakeNow);
      final api = FilenApi(
          client: MockClient((req) async => http.Response(
              json.encode({'status': false, 'message': 'boom'}), 200)));

      await cache.clearParentCache('item', 'file', api, crypto, [masterKey]);
      expect(cache.folderCache.containsKey('parent-uuid'), isTrue);
    });

    test('clearParentCache does nothing when the parent is null', () async {
      final cache = FilenCache(clock: () => fakeNow);
      cache.folderCache['parent-uuid'] =
          CacheEntry(items: const [], timestamp: fakeNow);
      final api = FilenApi(
          client: MockClient((req) async =>
              http.Response(json.encode({'status': true, 'data': {}}), 200)));

      await cache.clearParentCache('item', 'file', api, crypto, [masterKey]);
      expect(cache.folderCache.containsKey('parent-uuid'), isTrue);
    });
  });
}
