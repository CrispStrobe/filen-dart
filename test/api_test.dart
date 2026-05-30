import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:filen_dart/api.dart';

void main() {
  group('FilenApi', () {
    test('attaches auth header when apiKey is set', () async {
      String? capturedAuth;

      final mockClient = MockClient((request) async {
        capturedAuth = request.headers['Authorization'];
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
      });

      final api = FilenApi(client: mockClient);
      api.apiKey = 'test-api-key';

      await api.makeRequest('GET', Uri.parse('https://example.com/test'));
      expect(capturedAuth, equals('Bearer test-api-key'));
    });

    test('does not attach auth header when useAuth is false', () async {
      String? capturedAuth;

      final mockClient = MockClient((request) async {
        capturedAuth = request.headers['Authorization'];
        return http.Response(json.encode({'status': true}), 200);
      });

      final api = FilenApi(client: mockClient);
      api.apiKey = 'test-api-key';

      await api.makeRequest('GET', Uri.parse('https://example.com/test'),
          useAuth: false);
      expect(capturedAuth, isNull);
    });

    test('post parses JSON and checks status', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
            json.encode({
              'status': true,
              'data': {'foo': 'bar'}
            }),
            200);
      });

      final api = FilenApi(client: mockClient);
      api.apiKey = 'key';

      final result = await api.post('/v3/test', {'input': 'value'});
      expect(result['data']['foo'], equals('bar'));
    });

    test('post throws on status false', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
            json.encode({'status': false, 'message': 'Bad request'}), 200);
      });

      final api = FilenApi(client: mockClient);
      api.apiKey = 'key';

      expect(
        () => api.post('/v3/test', {}),
        throwsA(isA<Exception>()),
      );
    });

    test('throws on HTTP error after retries', () async {
      int callCount = 0;

      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response('Server Error', 500);
      });

      final api = FilenApi(client: mockClient);

      await expectLater(
        () => api.makeRequest('GET', Uri.parse('https://example.com/fail'),
            maxRetries: 2, useAuth: false),
        throwsA(isA<Exception>()),
      );
      expect(callCount, greaterThan(1));
    });

    test('supports POST method', () async {
      String? method;
      String? body;

      final mockClient = MockClient((request) async {
        method = request.method;
        body = request.body;
        return http.Response('{"status":true,"data":{}}', 200);
      });

      final api = FilenApi(client: mockClient);
      await api.makeRequest('POST', Uri.parse('https://example.com/'),
          body: '{"test":true}', useAuth: false);

      expect(method, equals('POST'));
      expect(body, equals('{"test":true}'));
    });

    test('supports GET method', () async {
      String? method;

      final mockClient = MockClient((request) async {
        method = request.method;
        return http.Response('{"status":true}', 200);
      });

      final api = FilenApi(client: mockClient);
      await api.makeRequest('GET', Uri.parse('https://example.com/'),
          useAuth: false);
      expect(method, equals('GET'));
    });
  });
}
