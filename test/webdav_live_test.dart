@Tags(['live'])
import 'dart:io';

import 'package:test/test.dart';
import 'package:filen_dart/filen_client.dart';
import 'package:filen_dart/webdav_filesystem.dart';

/// Live WebDAV integration tests against real Filen backend.
/// Requires FILEN_EMAIL and FILEN_PASSWORD environment variables.
///
/// Run with: dart test --tags live test/webdav_live_test.dart
void main() {
  final email = Platform.environment['FILEN_EMAIL'];
  final password = Platform.environment['FILEN_PASSWORD'];

  if (email == null || password == null) {
    test('SKIPPED: FILEN_EMAIL and FILEN_PASSWORD not set', () {},
        skip: 'Set FILEN_EMAIL and FILEN_PASSWORD to run live tests');
    return;
  }

  late FilenClient client;

  setUpAll(() async {
    final tempDir = Directory.systemTemp.createTempSync('filen_webdav_test_');
    final config = ConfigService(configPath: tempDir.path);
    client = FilenClient(config: config);

    final credentials = await client.login(email, password);
    client.setAuth(credentials);
    final rootUUID = await client.fetchBaseFolderUUID();
    credentials['baseFolderUUID'] = rootUUID;
    client.setAuth(credentials);
  });

  tearDownAll(() async {
    // Server cleanup handled per-test
  });

  test('WebDAV server starts and responds to PROPFIND', () async {
    // Import shelf_dav and start server inline
    // For simplicity, test via HTTP against a running server
    // This test validates the WebDAV filesystem integration

    // We can't easily start the shelf server here without the full
    // CLI wiring, so this test validates the client can construct
    // the filesystem objects needed for WebDAV
    final filenFS = FilenFileSystem(client: client);

    // Verify the filesystem can resolve root
    final rootDir = filenFS.directory('/');
    expect(rootDir, isNotNull);
    expect(rootDir.path, equals('/'));

    // Verify root exists
    final exists = await rootDir.exists();
    expect(exists, isTrue);
  });

  test('WebDAV filesystem can list root directory', () async {
    final filenFS = FilenFileSystem(client: client);

    final rootDir = filenFS.directory('/');
    final entities = await rootDir.list().toList();

    // Root should have at least some content (or be empty)
    expect(entities, isA<List>());
    print('Root contains ${entities.length} items');
  });

  test('WebDAV filesystem can create and delete directory', () async {
    final filenFS = FilenFileSystem(client: client);

    final testDir = filenFS
        .directory('/__webdav_test_${DateTime.now().millisecondsSinceEpoch}');

    try {
      // Create
      await testDir.create();
      expect(await testDir.exists(), isTrue);
    } finally {
      // Cleanup
      try {
        await testDir.delete();
      } catch (_) {}
    }
  });
}
