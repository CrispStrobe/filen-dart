import 'dart:typed_data';

import 'package:filen_client/aes_gcm_backend.dart';
import 'package:test/test.dart';

void main() {
  test('every Filen backend rejects non-AES-256 keys', () async {
    final backends = [
      CryptographyBackend(),
      PointycastleBackend((length) => Uint8List(length)),
      chooseAesGcmBackend(),
    ];
    final plaintext = Uint8List.fromList([1, 2, 3]);
    final key = Uint8List(32);
    for (final backend in backends) {
      final ciphertext = await backend.encryptData(key, plaintext);
      for (final length in [0, 1, 16, 24, 31, 33, 48, 64]) {
        final invalidKey = Uint8List(length);
        await expectLater(
          backend.encryptData(invalidKey, plaintext),
          throwsArgumentError,
          reason: '${backend.name}: $length-byte encryption key',
        );
        await expectLater(
          backend.decryptData(invalidKey, ciphertext),
          throwsArgumentError,
          reason: '${backend.name}: $length-byte decryption key',
        );
      }
      for (final length in [0, 1, 12, 27]) {
        await expectLater(
          backend.decryptData(key, Uint8List(length)),
          throwsFormatException,
        );
      }
    }
  });
}
