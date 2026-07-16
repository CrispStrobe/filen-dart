import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:filen_client/api.dart';

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

      await expectLater(
        () => api.post('/v3/test', {}),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('Bad request'))),
      );
    });

    test('retries 5xx then throws after exhausting maxRetries', () async {
      int callCount = 0;

      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response('Server Error', 500);
      });

      final api = FilenApi(client: mockClient);

      await expectLater(
        () => api.makeRequest('GET', Uri.parse('https://example.com/fail'),
            maxRetries: 2, useAuth: false),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('API Error: 500'))),
      );
      // 1 initial attempt + 2 retries.
      expect(callCount, equals(3));
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

    test('dispatches PUT, PATCH and DELETE methods', () async {
      final seen = <String>[];
      final mockClient = MockClient((request) async {
        seen.add(request.method);
        return http.Response('', 200);
      });
      final api = FilenApi(client: mockClient);

      for (final m in ['PUT', 'PATCH', 'DELETE']) {
        await api.makeRequest(m, Uri.parse('https://example.com/'),
            body: '{}', useAuth: false);
      }
      expect(seen, equals(['PUT', 'PATCH', 'DELETE']));
    });

    test('defaults Content-Type to application/json when no headers given',
        () async {
      String? contentType;
      final mockClient = MockClient((request) async {
        contentType = request.headers['content-type'];
        return http.Response('{"status":true}', 200);
      });
      final api = FilenApi(client: mockClient);
      await api.makeRequest('GET', Uri.parse('https://example.com/'),
          useAuth: false);
      expect(contentType, contains('application/json'));
    });

    test('does not mutate the caller-supplied headers map', () async {
      final mockClient =
          MockClient((request) async => http.Response('{"status":true}', 200));
      final api = FilenApi(client: mockClient);
      api.apiKey = 'k';

      final callerHeaders = <String, String>{'X-Custom': '1'};
      await api.makeRequest('GET', Uri.parse('https://example.com/'),
          headers: callerHeaders);
      // The Authorization injection must not leak into the caller's map.
      expect(callerHeaders.containsKey('Authorization'), isFalse);
      expect(callerHeaders, equals({'X-Custom': '1'}));
    });

    test('surfaces a 4xx response as "API Error: <code>"', () async {
      final mockClient =
          MockClient((request) async => http.Response('Forbidden', 403));
      final api = FilenApi(client: mockClient);

      await expectLater(
        () => api.makeRequest('GET', Uri.parse('https://example.com/'),
            useAuth: false),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message',
            allOf(contains('API Error: 403'), contains('Forbidden')))),
      );
    });

    test('returns a 200 with an empty body without throwing', () async {
      final mockClient = MockClient((request) async => http.Response('', 200));
      final api = FilenApi(client: mockClient);

      final r = await api.makeRequest(
          'DELETE', Uri.parse('https://example.com/'),
          useAuth: false);
      expect(r.statusCode, equals(200));
      expect(r.body, isEmpty);
    });

    test('retries on transport errors then gives up', () async {
      int attempts = 0;
      final mockClient = MockClient((request) async {
        attempts++;
        throw http.ClientException('connection reset');
      });
      final api = FilenApi(client: mockClient);

      await expectLater(
        () => api.makeRequest('GET', Uri.parse('https://example.com/'),
            useAuth: false, maxRetries: 0),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message',
            contains('Network request failed'))),
      );
      expect(attempts, equals(1)); // maxRetries:0 -> single attempt
    });

    test('recovers when a transport error is followed by success', () async {
      int attempts = 0;
      final mockClient = MockClient((request) async {
        attempts++;
        if (attempts == 1) throw http.ClientException('transient');
        return http.Response('{"status":true}', 200);
      });
      final api = FilenApi(client: mockClient);

      final r = await api.makeRequest('GET', Uri.parse('https://example.com/'),
          useAuth: false, maxRetries: 1);
      expect(r.statusCode, equals(200));
      expect(attempts, equals(2));
    });
  });
}
