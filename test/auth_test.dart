import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:filen_client/api.dart';
import 'package:filen_client/auth.dart';
import 'package:filen_client/crypto.dart';

void main() {
  group('FilenAuth', () {
    test('getAuthInfo returns auth version and salt', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/v3/auth/info') {
          return http.Response(
              json.encode({
                'status': true,
                'data': {'authVersion': 2, 'salt': 'test-salt'}
              }),
              200);
        }
        return http.Response('Not found', 404);
      });

      final api = FilenApi(client: mockClient);
      final crypto = FilenCrypto();
      final auth = FilenAuth(api: api, crypto: crypto);

      final info = await auth.getAuthInfo('test@example.com');
      expect(info['authVersion'], equals(2));
      expect(info['salt'], equals('test-salt'));
    });

    test('fetchBaseFolderUUID returns UUID', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/v3/user/baseFolder') {
          return http.Response(
              json.encode({
                'status': true,
                'data': {'uuid': 'root-uuid-123'}
              }),
              200);
        }
        return http.Response('Not found', 404);
      });

      final api = FilenApi(client: mockClient);
      api.apiKey = 'test-key';
      final crypto = FilenCrypto();
      final auth = FilenAuth(api: api, crypto: crypto);

      final uuid = await auth.fetchBaseFolderUUID();
      expect(uuid, equals('root-uuid-123'));
    });

    test('login throws on 2FA required', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/v3/auth/info') {
          return http.Response(
              json.encode({
                'status': true,
                'data': {'authVersion': 2, 'salt': 'salt'}
              }),
              200);
        }
        if (request.url.path == '/v3/login') {
          return http.Response(
              json.encode({
                'status': false,
                'code': 'enter_2fa',
                'message': '2FA required'
              }),
              200);
        }
        return http.Response('Not found', 404);
      });

      final api = FilenApi(client: mockClient);
      final crypto = FilenCrypto();
      final auth = FilenAuth(api: api, crypto: crypto);

      await expectLater(
        () => auth.login('test@example.com', 'password'),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('enter_2fa'))),
      );
    });

    test('login throws on wrong 2FA code', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/v3/auth/info') {
          return http.Response(
              json.encode({
                'status': true,
                'data': {'authVersion': 2, 'salt': 'salt'}
              }),
              200);
        }
        if (request.url.path == '/v3/login') {
          return http.Response(
              json.encode(
                  {'status': false, 'code': 'wrong_2fa', 'message': 'Invalid'}),
              200);
        }
        return http.Response('Not found', 404);
      });
      final auth =
          FilenAuth(api: FilenApi(client: mockClient), crypto: FilenCrypto());
      await expectLater(
        () => auth.login('test@example.com', 'password', twoFactorCode: '000'),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('wrong_2fa'))),
      );
    });

    test('login surfaces a generic failure message', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/v3/auth/info') {
          return http.Response(
              json.encode({
                'status': true,
                'data': {'authVersion': 2, 'salt': 'salt'}
              }),
              200);
        }
        if (request.url.path == '/v3/login') {
          return http.Response(
              json.encode(
                  {'status': false, 'message': 'Invalid email or password'}),
              200);
        }
        return http.Response('Not found', 404);
      });
      final auth =
          FilenAuth(api: FilenApi(client: mockClient), crypto: FilenCrypto());
      await expectLater(
        () => auth.login('test@example.com', 'password'),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message',
            contains('Invalid email or password'))),
      );
    });

    test('getAuthInfo surfaces a failure message', () async {
      final mockClient = MockClient((request) async => http.Response(
          json.encode({'status': false, 'message': 'Account not found'}), 200));
      final auth =
          FilenAuth(api: FilenApi(client: mockClient), crypto: FilenCrypto());
      await expectLater(
        () => auth.getAuthInfo('nobody@example.com'),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('Account not found'))),
      );
    });

    test('login decrypts master keys and returns the credential map', () async {
      final crypto = FilenCrypto();
      final derived = await crypto.deriveKeys('password', 2, 'salt');
      final localMasterKey = derived['masterKey']!;
      // The server stores the real master key encrypted under the derived key.
      final encryptedMk =
          await crypto.encryptMetadata002('plain-master-key', localMasterKey);

      String? loginEmail;
      final mockClient = MockClient((request) async {
        if (request.url.path == '/v3/auth/info') {
          return http.Response(
              json.encode({
                'status': true,
                'data': {'authVersion': 2, 'salt': 'salt'}
              }),
              200);
        }
        if (request.url.path == '/v3/login') {
          loginEmail = (json.decode(request.body) as Map)['email'] as String?;
          return http.Response(
              json.encode({
                'status': true,
                'data': {
                  'apiKey': 'API-KEY',
                  'masterKeys': encryptedMk,
                  'baseFolderUUID': 'base-uuid',
                  'id': 42,
                }
              }),
              200);
        }
        return http.Response('Not found', 404);
      });

      final auth = FilenAuth(api: FilenApi(client: mockClient), crypto: crypto);
      final creds = await auth.login('Test@Example.com', 'password');

      expect(creds['email'], equals('Test@Example.com'));
      expect(creds['apiKey'], equals('API-KEY'));
      expect(creds['masterKeys'], equals('plain-master-key'));
      expect(creds['baseFolderUUID'], equals('base-uuid'));
      expect(creds['userId'], equals('42'));
      // Email is lowercased in the outgoing login payload.
      expect(loginEmail, equals('test@example.com'));
    });

    test('login falls back to the local master key when decryption fails',
        () async {
      final crypto = FilenCrypto();
      final derived = await crypto.deriveKeys('password', 2, 'salt');
      final localMasterKey = derived['masterKey']!;

      final mockClient = MockClient((request) async {
        if (request.url.path == '/v3/auth/info') {
          return http.Response(
              json.encode({
                'status': true,
                'data': {'authVersion': 2, 'salt': 'salt'}
              }),
              200);
        }
        if (request.url.path == '/v3/login') {
          return http.Response(
              json.encode({
                'status': true,
                'data': {
                  'apiKey': 'API-KEY',
                  'masterKeys': 'undecryptable-garbage',
                  'baseFolderUUID': 'base-uuid',
                }
              }),
              200);
        }
        return http.Response('Not found', 404);
      });

      final auth = FilenAuth(api: FilenApi(client: mockClient), crypto: crypto);
      final creds = await auth.login('test@example.com', 'password');
      expect(creds['masterKeys'], equals(localMasterKey));
    });

    test('fetchBaseFolderUUID falls back to a top-level uuid field', () async {
      final mockClient = MockClient((request) async =>
          http.Response(json.encode({'uuid': 'top-level-uuid'}), 200));
      final auth = FilenAuth(
          api: FilenApi(client: mockClient)..apiKey = 'k',
          crypto: FilenCrypto());
      expect(await auth.fetchBaseFolderUUID(), equals('top-level-uuid'));
    });
  });
}
