import 'dart:convert';
import 'dart:io';

import 'package:filen_client/filen_client.dart';

/// Path to a saved CLI session, used as a fallback when FILEN_EMAIL/PASSWORD
/// are not set (overridable via the FILEN_CREDENTIALS env var).
String savedCredentialsPath() =>
    Platform.environment['FILEN_CREDENTIALS'] ??
    '${Platform.environment['HOME']}/.filen-cli/credentials.json';

/// True when live tests can authenticate: either env credentials are present
/// or a saved CLI session exists on disk.
bool liveCredentialsAvailable() {
  final hasEnv = Platform.environment['FILEN_EMAIL'] != null &&
      Platform.environment['FILEN_PASSWORD'] != null;
  return hasEnv || File(savedCredentialsPath()).existsSync();
}

/// Authenticate a fresh [FilenClient] for live tests.
///
/// Prefers FILEN_EMAIL/FILEN_PASSWORD (full login). Otherwise reuses a saved
/// CLI session (apiKey + master keys), which avoids needing the password.
Future<FilenClient> authenticateForLiveTest() async {
  final tempDir = Directory.systemTemp.createTempSync('filen_live_test_');
  final client = FilenClient(config: ConfigService(configPath: tempDir.path));

  final email = Platform.environment['FILEN_EMAIL'];
  final password = Platform.environment['FILEN_PASSWORD'];

  if (email != null && password != null) {
    final creds = await client.login(email, password);
    client.setAuth(creds);
    creds['baseFolderUUID'] = await client.fetchBaseFolderUUID();
    client.setAuth(creds);
    return client;
  }

  final file = File(savedCredentialsPath());
  if (await file.exists()) {
    final creds =
        json.decode(await file.readAsString()) as Map<String, dynamic>;
    if ((creds['apiKey'] ?? '').toString().isNotEmpty) {
      client.setAuth(creds);
      return client;
    }
  }

  throw StateError('No live credentials available');
}
