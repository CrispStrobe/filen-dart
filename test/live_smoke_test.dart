@Tags(['live'])
import 'dart:io';

import 'package:test/test.dart';
import 'package:filen_dart/filen_client.dart';

/// Live integration tests against real Filen backend.
/// Requires FILEN_EMAIL and FILEN_PASSWORD environment variables.
/// All operations are confined to a test folder and cleaned up on teardown.
///
/// Run with: dart test --tags live
void main() {
  final email = Platform.environment['FILEN_EMAIL'];
  final password = Platform.environment['FILEN_PASSWORD'];

  if (email == null || password == null) {
    test('SKIPPED: FILEN_EMAIL and FILEN_PASSWORD not set', () {
      // This test exists so the file doesn't fail when credentials aren't set
    }, skip: 'Set FILEN_EMAIL and FILEN_PASSWORD to run live tests');
    return;
  }

  late FilenClient client;
  late ConfigService config;
  late String testFolderPath;

  setUpAll(() async {
    final tempDir = Directory.systemTemp.createTempSync('filen_live_test_');
    config = ConfigService(configPath: tempDir.path);
    client = FilenClient(config: config);

    final credentials = await client.login(email, password);
    client.setAuth(credentials);
    final rootUUID = await client.fetchBaseFolderUUID();
    credentials['baseFolderUUID'] = rootUUID;
    client.setAuth(credentials);

    // Create a unique test folder
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    testFolderPath = '/__test_filen_dart_smoke__/$timestamp';

    await client.createFolderRecursive(testFolderPath);
    print('Test folder: $testFolderPath');
  });

  tearDownAll(() async {
    // Clean up test folder
    try {
      final resolved = await client.resolvePath(testFolderPath);
      await client.trashItem(resolved['uuid'], 'folder');
      await client.deletePermanently(resolved['uuid'], 'folder');
    } catch (e) {
      print('Cleanup warning: $e');
    }
    // Also clean parent
    try {
      final parent = await client.resolvePath('/__test_filen_dart_smoke__');
      await client.trashItem(parent['uuid'], 'folder');
      await client.deletePermanently(parent['uuid'], 'folder');
    } catch (_) {}
  });

  test('login succeeds', () async {
    expect(client.baseFolderUUID, isNotEmpty);
    expect(client.masterKeys, isNotEmpty);
  });

  test('resolve root path', () async {
    final root = await client.resolvePath('/');
    expect(root['type'], equals('folder'));
    expect(root['uuid'], equals(client.baseFolderUUID));
  });

  test('create and resolve subfolder', () async {
    final subPath = '$testFolderPath/subfolder';
    await client.createFolderRecursive(subPath);

    final resolved = await client.resolvePath(subPath);
    expect(resolved['type'], equals('folder'));
    expect(resolved['uuid'], isNotEmpty);
  });

  test('upload, verify, and download file', () async {
    // Create a temp file
    final tempFile = File('${Directory.systemTemp.path}/filen_test_upload.txt');
    await tempFile.writeAsString('Hello from filen-dart live test!');

    try {
      // Upload
      final result = await client.uploadFileChunked(
        tempFile,
        (await client.resolvePath(testFolderPath))['uuid'],
      );
      expect(result['uuid'], isNotEmpty);

      // Verify
      final match =
          await client.verifyUploadMetadata(result['uuid']!, tempFile);
      expect(match, isTrue);

      // Download
      final downloadResult = await client.downloadFile(result['uuid']!,
          savePath: '${Directory.systemTemp.path}/filen_test_download.txt');
      expect(downloadResult['filename'], isNotEmpty);

      // Compare
      final downloaded =
          await File('${Directory.systemTemp.path}/filen_test_download.txt')
              .readAsString();
      expect(downloaded, equals('Hello from filen-dart live test!'));
    } finally {
      if (tempFile.existsSync()) tempFile.deleteSync();
      final dl = File('${Directory.systemTemp.path}/filen_test_download.txt');
      if (dl.existsSync()) dl.deleteSync();
    }
  });

  test('list folder contents', () async {
    final resolved = await client.resolvePath(testFolderPath);
    final folders = await client.listFoldersAsync(resolved['uuid']);
    // We created a subfolder above
    expect(folders, isA<List>());
  });

  test('search finds files', () async {
    final results = await client.search('filen_test');
    expect(results, isA<Map>());
  });

  test('trash content is listable', () async {
    final trash = await client.getTrashContent();
    expect(trash, isA<List>());
  });
}
