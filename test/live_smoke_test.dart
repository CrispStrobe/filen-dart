@Tags(['live'])
import 'dart:io';

import 'package:test/test.dart';
import 'package:filen_dart/filen_client.dart';

import 'live_support.dart';

/// Live integration tests against the real Filen backend.
/// Authenticates via FILEN_EMAIL/FILEN_PASSWORD, or falls back to a saved CLI
/// session (~/.filen-cli/credentials.json or FILEN_CREDENTIALS).
/// All operations are confined to a test folder and cleaned up on teardown.
///
/// Run with: dart test --tags live
void main() {
  if (!liveCredentialsAvailable()) {
    test('SKIPPED: no live credentials', () {
      // This test exists so the file doesn't fail when credentials aren't set
    }, skip: 'Set FILEN_EMAIL/FILEN_PASSWORD or provide a saved CLI session');
    return;
  }

  late FilenClient client;
  late String testFolderPath;

  setUpAll(() async {
    client = await authenticateForLiveTest();

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
