import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:filen_dart/api.dart';
import 'package:filen_dart/auth.dart';
import 'package:filen_dart/crypto.dart';

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

      expect(
        () => auth.login('test@example.com', 'password'),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('enter_2fa'))),
      );
    });
  });
}
