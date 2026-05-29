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
  });
}
