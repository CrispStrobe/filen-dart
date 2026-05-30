/// Configuration and state management for the Filen CLI.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'package:filen_dart/config_storage.dart';

class ConfigService {
  late final String configDir;
  late final String credentialsFile;
  late final String batchStateDir;
  late final String webdavPidFile;
  late final ConfigStorage _storage;

  ConfigService({required String configPath, ConfigStorage? storage}) {
    configDir = configPath;
    credentialsFile = p.join(configDir, 'credentials.json');
    batchStateDir = p.join(configDir, 'batch_states');
    webdavPidFile = p.join(configDir, 'webdav.pid');

    _storage = storage ?? FileConfigStorage(credentialsFile: credentialsFile);

    try {
      Directory(configDir).createSync(recursive: true);
      Directory(batchStateDir).createSync(recursive: true);
    } catch (e) {
      print("⚠️ Warning: Could not create config directory: $e");
    }
  }

  // --- Credential management (delegated to ConfigStorage) ---

  Future<void> saveCredentials(Map<String, dynamic> data) =>
      _storage.saveCredentials(data);

  Future<Map<String, dynamic>?> readCredentials() => _storage.readCredentials();

  Future<void> clearCredentials() => _storage.clearCredentials();

  // --- WebDAV PID management ---

  Future<int?> readWebdavPid() async {
    final file = File(webdavPidFile);
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        return int.tryParse(content.trim());
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<void> saveWebdavPid(int pid) async {
    final file = File(webdavPidFile);
    await file.writeAsString(pid.toString());
  }

  Future<void> clearWebdavPid() async {
    final file = File(webdavPidFile);
    if (await file.exists()) {
      await file.delete();
    }
  }

  // --- Batch state management ---

  String generateBatchId(
      String operationType, List<String> sources, String target) {
    final input = '$operationType-${sources.join('|')}-$target';
    final bytes = utf8.encode(input);
    final digest = crypto.sha1.convert(bytes);
    return digest.toString().substring(0, 16);
  }

  String getBatchStateFilePath(String batchId) {
    return p.join(batchStateDir, 'batch_state_$batchId.json');
  }

  Future<Map<String, dynamic>?> loadBatchState(String batchId) async {
    final filePath = getBatchStateFilePath(batchId);
    final file = File(filePath);
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        return json.decode(content) as Map<String, dynamic>;
      } catch (e) {
        print("⚠️ Could not read batch state: $e");
        await deleteBatchState(batchId);
        return null;
      }
    }
    return null;
  }

  Future<void> saveBatchState(
      String batchId, Map<String, dynamic> state) async {
    final filePath = getBatchStateFilePath(batchId);
    final file = File(filePath);
    try {
      await file.writeAsString(json.encode(state));
    } catch (e) {
      print("⚠️ Could not save batch state: $e");
    }
  }

  Future<void> deleteBatchState(String batchId) async {
    final filePath = getBatchStateFilePath(batchId);
    final file = File(filePath);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (e) {
        print("⚠️ Could not delete batch state: $e");
      }
    }
  }
}
