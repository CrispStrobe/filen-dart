import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:filen_dart/config.dart';
import 'package:filen_dart/config_storage.dart';

void main() {
  late ConfigService config;
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('filen_test_');
    config = ConfigService(
      configPath: tempDir.path,
      storage: InMemoryConfigStorage(),
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('credentials', () {
    test('save and read round-trip', () async {
      final creds = {
        'email': 'test@example.com',
        'apiKey': 'abc123',
        'masterKeys': 'key1|key2',
        'baseFolderUUID': 'uuid-123',
      };

      await config.saveCredentials(creds);
      final read = await config.readCredentials();
      expect(read, isNotNull);
      expect(read!['email'], equals('test@example.com'));
      expect(read['apiKey'], equals('abc123'));
      expect(read['masterKeys'], equals('key1|key2'));
    });

    test('read returns null when not set', () async {
      final read = await config.readCredentials();
      expect(read, isNull);
    });

    test('clear removes credentials', () async {
      await config.saveCredentials({'email': 'test@example.com'});
      await config.clearCredentials();
      final read = await config.readCredentials();
      expect(read, isNull);
    });
  });

  group('construction', () {
    test('creates config and batch-state directories', () {
      expect(Directory(config.configDir).existsSync(), isTrue);
      expect(Directory(config.batchStateDir).existsSync(), isTrue);
    });

    test('defaults to FileConfigStorage when no storage is injected', () {
      final fileBacked = ConfigService(configPath: tempDir.path);
      expect(fileBacked.storage, isA<FileConfigStorage>());
    });
  });

  // Tests exercising the production FileConfigStorage path (default storage).
  group('FileConfigStorage (on-disk)', () {
    late ConfigService fileConfig;

    setUp(() {
      fileConfig = ConfigService(configPath: tempDir.path);
    });

    test('direct round-trip via FileConfigStorage', () async {
      final fs = FileConfigStorage(
          credentialsFile: '${tempDir.path}/direct_creds.json');
      expect(await fs.readCredentials(), isNull);
      await fs.saveCredentials({'k': 'v'});
      expect((await fs.readCredentials())!['k'], equals('v'));
      await fs.clearCredentials();
      expect(await fs.readCredentials(), isNull);
    });

    test('readCredentials returns null on corrupt JSON', () async {
      await File(fileConfig.credentialsFile).writeAsString('not-valid-json{{');
      expect(await fileConfig.readCredentials(), isNull);
    });

    test('credentials are encrypted at rest (default file storage)', () async {
      await fileConfig
          .saveCredentials({'apiKey': 'sentinel-token-abcdef-12345'});
      final raw = await File(fileConfig.credentialsFile).readAsString();
      // The secret must NOT appear in cleartext on disk.
      expect(raw.contains('sentinel-token-abcdef-12345'), isFalse);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['fmt'], equals(credentialsFmt));
      expect(env['ct'], isA<String>());
      // ...and it still round-trips back through readCredentials.
      final read = await fileConfig.readCredentials();
      expect(read!['apiKey'], equals('sentinel-token-abcdef-12345'));
    });

    test('reads + migrates a legacy plaintext-JSON credentials file', () async {
      // Pre-encryption format: raw credentials JSON written directly.
      await File(fileConfig.credentialsFile)
          .writeAsString(jsonEncode({'apiKey': 'legacy-token-xyz'}));
      // First read returns the legacy creds...
      final read = await fileConfig.readCredentials();
      expect(read!['apiKey'], equals('legacy-token-xyz'));
      // ...and migrates the file to the encrypted envelope in place.
      final raw = await File(fileConfig.credentialsFile).readAsString();
      expect(raw.contains('legacy-token-xyz'), isFalse);
      expect((jsonDecode(raw) as Map)['fmt'], equals(credentialsFmt));
      // The migrated file still round-trips.
      expect((await fileConfig.readCredentials())!['apiKey'],
          equals('legacy-token-xyz'));
    });

    test('clear removes the on-disk credentials file', () async {
      await fileConfig.saveCredentials({'apiKey': 'x'});
      expect(File(fileConfig.credentialsFile).existsSync(), isTrue);
      await fileConfig.clearCredentials();
      expect(File(fileConfig.credentialsFile).existsSync(), isFalse);
    });

    test('clear is a no-op when no file exists', () async {
      await fileConfig.clearCredentials(); // must not throw
      expect(await fileConfig.readCredentials(), isNull);
    });

    test('InMemoryConfigStorage keeps credentials off disk', () async {
      await config.saveCredentials({'apiKey': 'mem'});
      expect(File(config.credentialsFile).existsSync(), isFalse);
    });
  });

  group('generateBatchId', () {
    test('is deterministic', () {
      final id1 = config.generateBatchId('upload', ['file.txt'], '/docs');
      final id2 = config.generateBatchId('upload', ['file.txt'], '/docs');
      expect(id1, equals(id2));
    });

    test('differs for different inputs', () {
      final id1 = config.generateBatchId('upload', ['file.txt'], '/docs');
      final id2 = config.generateBatchId('download', ['file.txt'], '/docs');
      expect(id1, isNot(equals(id2)));
    });

    test('returns 16-char string', () {
      final id = config.generateBatchId('upload', ['a.txt'], '/');
      expect(id.length, equals(16));
    });

    test('differs for different sources', () {
      expect(config.generateBatchId('upload', ['a'], '/d'),
          isNot(equals(config.generateBatchId('upload', ['b'], '/d'))));
    });

    test('differs for different target', () {
      expect(config.generateBatchId('upload', ['a'], '/d1'),
          isNot(equals(config.generateBatchId('upload', ['a'], '/d2'))));
    });

    test('source order matters', () {
      expect(config.generateBatchId('upload', ['a', 'b'], '/d'),
          isNot(equals(config.generateBatchId('upload', ['b', 'a'], '/d'))));
    });
  });

  group('batch state', () {
    test('save, load, delete', () async {
      final batchId = 'test-batch-id-01';
      final state = {
        'operationType': 'upload',
        'tasks': [
          {'localPath': '/tmp/file.txt', 'status': 'pending'}
        ]
      };

      await config.saveBatchState(batchId, state);
      final loaded = await config.loadBatchState(batchId);
      expect(loaded, isNotNull);
      expect(loaded!['operationType'], equals('upload'));
      expect((loaded['tasks'] as List).length, equals(1));

      await config.deleteBatchState(batchId);
      final deleted = await config.loadBatchState(batchId);
      expect(deleted, isNull);
    });

    test('load returns null when not exists', () async {
      final loaded = await config.loadBatchState('nonexistent');
      expect(loaded, isNull);
    });

    test('load self-heals a corrupt state file (deletes + returns null)',
        () async {
      final fp = config.getBatchStateFilePath('corrupted-batch');
      await File(fp).writeAsString('not-valid-json{{');
      expect(await config.loadBatchState('corrupted-batch'), isNull);
      expect(File(fp).existsSync(), isFalse);
    });

    test('delete removes the on-disk state file', () async {
      const id = 'del-batch';
      await config.saveBatchState(id, {'x': 1});
      expect(File(config.getBatchStateFilePath(id)).existsSync(), isTrue);
      await config.deleteBatchState(id);
      expect(File(config.getBatchStateFilePath(id)).existsSync(), isFalse);
    });

    test('delete is a no-op when no file exists', () async {
      await config.deleteBatchState('never-saved'); // must not throw
      expect(await config.loadBatchState('never-saved'), isNull);
    });

    test('multiple batches do not interfere', () async {
      await config.saveBatchState('batch-a', {'which': 'a'});
      await config.saveBatchState('batch-b', {'which': 'b'});
      expect((await config.loadBatchState('batch-a'))!['which'], equals('a'));
      expect((await config.loadBatchState('batch-b'))!['which'], equals('b'));
    });
  });

  group('webdav PID', () {
    test('save and read', () async {
      await config.saveWebdavPid(12345);
      final pid = await config.readWebdavPid();
      expect(pid, equals(12345));
    });

    test('read returns null when not set', () async {
      final pid = await config.readWebdavPid();
      expect(pid, isNull);
    });

    test('clear removes PID', () async {
      await config.saveWebdavPid(12345);
      await config.clearWebdavPid();
      final pid = await config.readWebdavPid();
      expect(pid, isNull);
    });

    test('read returns null on non-numeric content', () async {
      await File(config.webdavPidFile).writeAsString('not-a-number');
      expect(await config.readWebdavPid(), isNull);
    });

    test('clear is a no-op when no PID file exists', () async {
      await config.clearWebdavPid(); // must not throw
      expect(await config.readWebdavPid(), isNull);
    });
  });
}
