import 'dart:io' as io;
import 'dart:typed_data';

import 'package:file/file.dart';
import 'package:test/test.dart';
import 'package:filen_dart/filen_client.dart';
import 'package:filen_dart/webdav_filesystem.dart';

/// In-memory FilenClient: overrides the handful of methods the WebDAV
/// filesystem calls so the FileSystem/File/Directory behaviour can be tested
/// without a network or credentials.
class FakeFilenClient extends FilenClient {
  final Map<String, Map<String, dynamic>> paths;
  final Map<String, List<Map<String, dynamic>>> folderChildren;
  final Map<String, List<Map<String, dynamic>>> fileChildren;
  final Map<String, Uint8List> fileBytes;

  final List<String> trashed = [];
  final List<String> uploadedParents = [];
  final List<String> renamed = [];
  final List<String> moved = [];

  FakeFilenClient({
    this.paths = const {},
    this.folderChildren = const {},
    this.fileChildren = const {},
    this.fileBytes = const {},
  }) : super(
            config: ConfigService(
                configPath: '/tmp/filen_webdav_fake', // unused (in-memory)
                storage: InMemoryConfigStorage()));

  @override
  Future<Map<String, dynamic>> resolvePath(String path) async {
    final r = paths[path];
    if (r == null) throw Exception('Path not found: $path');
    return r;
  }

  @override
  Future<void> trashItem(String uuid, String type) async => trashed.add(uuid);

  @override
  Future<void> uploadFile(io.File file, String parent,
          {String? creationTime, String? modificationTime}) async =>
      uploadedParents.add(parent);

  @override
  Future<List<Map<String, dynamic>>> listFoldersAsync(String uuid,
          {bool detailed = false}) async =>
      folderChildren[uuid] ?? [];

  @override
  Future<List<Map<String, dynamic>>> listFolderFiles(String uuid,
          {bool detailed = false}) async =>
      fileChildren[uuid] ?? [];

  @override
  Future<void> renameItem(String uuid, String newName, String type) async =>
      renamed.add('$uuid:$newName:$type');

  @override
  Future<void> moveItem(String uuid, String dest, String type) async =>
      moved.add('$uuid->$dest:$type');

  @override
  Future<Map<String, dynamic>> downloadFile(String uuid,
          {String? savePath,
          int maxConcurrentChunks = kDefaultDownloadConcurrency,
          Function(int, int)? onProgress}) async =>
      {'data': fileBytes[uuid] ?? Uint8List(0), 'filename': 'x'};

  @override
  void log(String msg) {}
}

void main() {
  group('FilenFileSystem (mocked client)', () {
    test('writeAsBytes uploads to the resolved parent (new file, no trash)',
        () async {
      final client = FakeFilenClient(paths: {
        '/': {'type': 'folder', 'uuid': 'parent-uuid'},
        // '/new.txt' intentionally absent -> fresh upload
      });
      final fs = FilenFileSystem(client: client);

      await fs.file('/new.txt').writeAsBytes([1, 2, 3]);

      expect(client.uploadedParents, equals(['parent-uuid']));
      expect(client.trashed, isEmpty);
    });

    test('writeAsBytes over an existing file trashes the old uuid first',
        () async {
      final client = FakeFilenClient(paths: {
        '/': {'type': 'folder', 'uuid': 'parent-uuid'},
        '/exists.txt': {'type': 'file', 'uuid': 'old-uuid'},
      });
      final fs = FilenFileSystem(client: client);

      await fs.file('/exists.txt').writeAsBytes([9, 9, 9]);

      // The pre-existing file is trashed before the replacement is uploaded.
      expect(client.trashed, equals(['old-uuid']));
      expect(client.uploadedParents, equals(['parent-uuid']));
    });

    test('stat maps file metadata, folders, and not-found', () async {
      final client = FakeFilenClient(paths: {
        '/a.txt': {
          'type': 'file',
          'metadata': <String, dynamic>{
            'size': 42,
            'lastModified': 1700000000000
          }
        },
        '/dir': {'type': 'folder'},
      });
      final fs = FilenFileSystem(client: client);

      final fileStat = await fs.stat('/a.txt');
      expect(fileStat.type, equals(io.FileSystemEntityType.file));
      expect(fileStat.size, equals(42));
      expect(fileStat.modified,
          equals(DateTime.fromMillisecondsSinceEpoch(1700000000000)));

      final dirStat = await fs.stat('/dir');
      expect(dirStat.type, equals(io.FileSystemEntityType.directory));
      expect(dirStat.size, equals(-1));

      final missingStat = await fs.stat('/nope');
      expect(missingStat.type, equals(io.FileSystemEntityType.notFound));
    });

    test('type discriminates file / directory / not-found', () async {
      final client = FakeFilenClient(paths: {
        '/a.txt': {'type': 'file'},
        '/dir': {'type': 'folder'},
      });
      final fs = FilenFileSystem(client: client);
      expect(await fs.type('/a.txt'), equals(io.FileSystemEntityType.file));
      expect(await fs.type('/dir'), equals(io.FileSystemEntityType.directory));
      expect(await fs.type('/nope'), equals(io.FileSystemEntityType.notFound));
    });

    test('exists() discriminates files from folders', () async {
      final client = FakeFilenClient(paths: {
        '/a.txt': {'type': 'file', 'uuid': 'u'},
        '/dir': {'type': 'folder', 'uuid': 'd'},
      });
      final fs = FilenFileSystem(client: client);
      expect(await fs.file('/a.txt').exists(), isTrue);
      expect(await fs.file('/dir').exists(), isFalse); // it's a folder
      expect(await fs.directory('/dir').exists(), isTrue);
      expect(await fs.directory('/a.txt').exists(), isFalse);
      expect(await fs.file('/missing').exists(), isFalse);
    });

    test('directory.list returns child directories and files', () async {
      final client = FakeFilenClient(
        paths: {
          '/': {'type': 'folder', 'uuid': 'root'}
        },
        folderChildren: {
          'root': [
            {'name': 'sub'}
          ]
        },
        fileChildren: {
          'root': [
            {'name': 'a.txt'}
          ]
        },
      );
      final fs = FilenFileSystem(client: client);

      final entities = await fs.directory('/').list().toList();
      final paths = entities.map((e) => e.path).toSet();
      expect(paths, containsAll(<String>['/sub', '/a.txt']));
      expect(entities.firstWhere((e) => e.path == '/sub'), isA<Directory>());
      expect(entities.firstWhere((e) => e.path == '/a.txt'), isA<File>());
    });

    test('delete trashes with the correct item type', () async {
      final client = FakeFilenClient(paths: {
        '/a.txt': {'type': 'file', 'uuid': 'file-uuid'},
        '/dir': {'type': 'folder', 'uuid': 'dir-uuid'},
      });
      final fs = FilenFileSystem(client: client);

      await fs.file('/a.txt').delete();
      await fs.directory('/dir').delete();
      expect(client.trashed, equals(['file-uuid', 'dir-uuid']));
    });

    test('rename within the same parent calls renameItem only', () async {
      final client = FakeFilenClient(paths: {
        '/a.txt': {'type': 'file', 'uuid': 'file-uuid'},
      });
      final fs = FilenFileSystem(client: client);

      await fs.file('/a.txt').rename('/b.txt');
      expect(client.renamed, equals(['file-uuid:b.txt:file']));
      expect(client.moved, isEmpty);
    });

    test('rename across parents moves (no rename when name is unchanged)',
        () async {
      final client = FakeFilenClient(paths: {
        '/dir1/a.txt': {'type': 'file', 'uuid': 'file-uuid'},
        '/dir2': {'type': 'folder', 'uuid': 'dir2-uuid'},
      });
      final fs = FilenFileSystem(client: client);

      await fs.file('/dir1/a.txt').rename('/dir2/a.txt');
      expect(client.moved, equals(['file-uuid->dir2-uuid:file']));
      expect(client.renamed, isEmpty); // basename unchanged
    });

    test('readAsBytes returns the downloaded file content', () async {
      final client = FakeFilenClient(
        paths: {
          '/a.txt': {'type': 'file', 'uuid': 'file-uuid'}
        },
        fileBytes: {
          'file-uuid': Uint8List.fromList([7, 8, 9])
        },
      );
      final fs = FilenFileSystem(client: client);

      final bytes = await fs.file('/a.txt').readAsBytes();
      expect(bytes, equals(Uint8List.fromList([7, 8, 9])));
    });
  });
}
