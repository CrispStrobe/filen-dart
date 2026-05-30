import 'package:test/test.dart';
import 'package:filen_dart/filen_client.dart';

void main() {
  group('FilenClient facade', () {
    test('creates all sub-modules', () {
      final config = ConfigService(
        configPath:
            '/tmp/filen_cli_test_${DateTime.now().millisecondsSinceEpoch}',
        storage: InMemoryConfigStorage(),
      );
      final client = FilenClient(config: config);

      expect(client.api, isNotNull);
      expect(client.crypto, isNotNull);
      expect(client.cache, isNotNull);
      expect(client.auth, isNotNull);
      expect(client.drive, isNotNull);
      expect(client.uploader, isNotNull);
      expect(client.downloader, isNotNull);
    });

    test('setAuth propagates to all modules', () {
      final config = ConfigService(
        configPath:
            '/tmp/filen_cli_test_${DateTime.now().millisecondsSinceEpoch}',
        storage: InMemoryConfigStorage(),
      );
      final client = FilenClient(config: config);

      client.setAuth({
        'apiKey': 'test-api-key',
        'baseFolderUUID': 'root-uuid-123',
        'masterKeys': 'key1|key2|key3',
        'email': 'user@example.com',
      });

      expect(client.apiKey, equals('test-api-key'));
      expect(client.baseFolderUUID, equals('root-uuid-123'));
      expect(client.masterKeys, equals(['key1', 'key2', 'key3']));
      expect(client.email, equals('user@example.com'));
    });

    test('setAuth handles empty masterKeys', () {
      final config = ConfigService(
        configPath:
            '/tmp/filen_cli_test_${DateTime.now().millisecondsSinceEpoch}',
        storage: InMemoryConfigStorage(),
      );
      final client = FilenClient(config: config);

      client.setAuth({
        'apiKey': 'key',
        'baseFolderUUID': 'uuid',
        'masterKeys': '',
        'email': 'x@x.com',
      });

      expect(client.masterKeys, isEmpty);
    });

    test('debugMode propagates to api', () {
      final config = ConfigService(
        configPath:
            '/tmp/filen_cli_test_${DateTime.now().millisecondsSinceEpoch}',
        storage: InMemoryConfigStorage(),
      );
      final client = FilenClient(config: config);

      expect(client.debugMode, isFalse);
      client.debugMode = true;
      expect(client.debugMode, isTrue);
      expect(client.api.debugMode, isTrue);
    });

    test('apiKey getter/setter works', () {
      final config = ConfigService(
        configPath:
            '/tmp/filen_cli_test_${DateTime.now().millisecondsSinceEpoch}',
        storage: InMemoryConfigStorage(),
      );
      final client = FilenClient(config: config);

      client.apiKey = 'new-key';
      expect(client.apiKey, equals('new-key'));
    });

    test('baseFolderUUID getter/setter works', () {
      final config = ConfigService(
        configPath:
            '/tmp/filen_cli_test_${DateTime.now().millisecondsSinceEpoch}',
        storage: InMemoryConfigStorage(),
      );
      final client = FilenClient(config: config);

      client.baseFolderUUID = 'my-root';
      expect(client.baseFolderUUID, equals('my-root'));
    });

    test('shouldIncludeFile delegates to utils', () {
      final config = ConfigService(
        configPath:
            '/tmp/filen_cli_test_${DateTime.now().millisecondsSinceEpoch}',
        storage: InMemoryConfigStorage(),
      );
      final client = FilenClient(config: config);

      expect(client.shouldIncludeFile('test.txt', ['*.txt'], []), isTrue);
      expect(client.shouldIncludeFile('test.pdf', ['*.txt'], []), isFalse);
    });

    test('accepts custom http client', () {
      final config = ConfigService(
        configPath:
            '/tmp/filen_cli_test_${DateTime.now().millisecondsSinceEpoch}',
        storage: InMemoryConfigStorage(),
      );
      // Should not throw
      final client = FilenClient(config: config);
      expect(client, isNotNull);
    });
  });

  group('formatSize (CLI display)', () {
    test('handles common sizes', () {
      expect(formatSize(0), equals('0 B'));
      expect(formatSize(1024), equals('1.0 KB'));
      expect(formatSize(1048576), equals('1.0 MB'));
      expect(formatSize(1073741824), equals('1.0 GB'));
    });
  });

  group('ConfigStorage implementations', () {
    test('InMemoryConfigStorage round-trip', () async {
      final storage = InMemoryConfigStorage();

      expect(await storage.readCredentials(), isNull);

      await storage.saveCredentials({'key': 'value'});
      final read = await storage.readCredentials();
      expect(read, isNotNull);
      expect(read!['key'], equals('value'));

      await storage.clearCredentials();
      expect(await storage.readCredentials(), isNull);
    });

    test('InMemoryConfigStorage returns copies', () async {
      final storage = InMemoryConfigStorage();
      final data = {'key': 'value'};

      await storage.saveCredentials(data);
      final read1 = await storage.readCredentials();
      final read2 = await storage.readCredentials();

      // Should be equal but not identical (defensive copies)
      expect(read1, equals(read2));
      expect(identical(read1, read2), isFalse);
    });
  });
}
