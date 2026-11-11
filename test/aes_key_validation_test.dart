import 'dart:typed_data';

import 'package:filen_client/aes_gcm_backend.dart';
import 'package:test/test.dart';

void main() {
  test('every backend rejects non-AES-256 keys before cipher or FFI use',
      () async {
    final backends = [
      CryptographyBackend(),
      PointycastleBackend((length) => Uint8List(length)),
      chooseAesGcmBackend(),
    ];
    final data = Uint8List.fromList([1, 2, 3]);
    for (final backend in backends) {
      final ciphertext = await backend.encryptData(Uint8List(32), data);
      for (final length in [0, 1, 16, 24, 31, 33, 48, 64]) {
        await expectLater(backend.encryptData(Uint8List(length), data),
            throwsArgumentError,
            reason: '${backend.name}: $length-byte encryption key');
        await expectLater(backend.decryptData(Uint8List(length), ciphertext),
            throwsArgumentError,
            reason: '${backend.name}: $length-byte decryption key');
      }
      for (final length in [0, 1, 11, 12, 27]) {
        await expectLater(backend.decryptData(Uint8List(32), Uint8List(length)),
            throwsFormatException);
      }
    }
  });
}
