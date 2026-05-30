import 'package:test/test.dart';
import 'package:filen_dart/cache.dart';

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
  });
}
