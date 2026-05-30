import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:filen_dart/filen_client.dart';

/// Unit coverage for the path facade (`FilenPaths` extension) and the
/// network-free parts of path resolution. End-to-end happy paths
/// (upload/download/rename round-trips) live in the live smoke suite.
void main() {
  FilenClient unauthedClient() => FilenClient(
        config: ConfigService(
          configPath:
              '/tmp/filen_paths_test_${DateTime.now().microsecondsSinceEpoch}',
          storage: InMemoryConfigStorage(),
        ),
      );

  group('FilenPaths pre-auth gate', () {
    // Every path method ultimately resolves a path, which requires a
    // logged-in session. Without one each must fail cleanly (not NPE).
    late FilenClient client;

    setUp(() {
      client = unauthedClient();
    });

    test('downloadFromPath throws when not authenticated', () {
      expect(() => client.downloadFromPath('/Documents/x.pdf'),
          throwsA(isA<Exception>()));
    });

    test('trashByPath throws when not authenticated', () {
      expect(() => client.trashByPath('/Documents/x.pdf'),
          throwsA(isA<Exception>()));
    });

    test('renameByPath throws when not authenticated', () {
      expect(() => client.renameByPath('/Documents/x.pdf', 'y.pdf'),
          throwsA(isA<Exception>()));
    });

    test('moveByPath throws when not authenticated', () {
      expect(() => client.moveByPath('/Documents/x.pdf', '/Archive/'),
          throwsA(isA<Exception>()));
    });

    test('listPath throws when not authenticated', () {
      expect(() => client.listPath('/Documents'), throwsA(isA<Exception>()));
    });

    test('uploadToPath (directory target) throws when not authenticated', () {
      expect(() => client.uploadToPath(File('nonexistent'), '/Documents/'),
          throwsA(isA<Exception>()));
    });

    test('uploadToPath (file target) throws when not authenticated', () {
      expect(() => client.uploadToPath(File('nonexistent'), '/a/b.pdf'),
          throwsA(isA<Exception>()));
    });

    test('uploadFileBytes throws and leaves no temp artifacts', () async {
      final before = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.contains('filen_upload_'))
          .length;
      await expectLater(
        client.uploadFileBytes(Uint8List.fromList([0, 1, 2]), '/x.bin'),
        throwsA(isA<Exception>()),
      );
      final after = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.contains('filen_upload_'))
          .length;
      // The temp dir is only created after the (failing) folder resolution.
      expect(after, equals(before));
    });
  });

  group('resolvePath normalization (offline, root-resolving inputs)', () {
    late FilenClient client;

    setUp(() {
      client = unauthedClient();
      // A session is "present" once a base folder is known; root-resolving
      // inputs return without any network access.
      client.baseFolderUUID = 'root-uuid';
    });

    for (final input in ['/', '', '.', '   /   ', '///']) {
      test('resolves ${input.isEmpty ? '<empty>' : '"$input"'} to root',
          () async {
        final r = await client.resolvePath(input);
        expect(r['type'], equals('folder'));
        expect(r['uuid'], equals('root-uuid'));
        expect(r['path'], equals('/'));
      });
    }
  });
}
