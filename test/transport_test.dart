import 'dart:async';
import 'dart:convert';

import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final uri = Uri.parse('https://www.closeyour.it/api/v1/projects/p/events');

  group('Transport.send', () {
    test('202 → status 202 and stats.sent', () async {
      final stats = Stats();
      final t = Transport(
        token: 'cyi_x',
        stats: stats,
        client: MockClient((_) async => http.Response('{"data":{}}', 202)),
      );
      final status = await t.send({'a': 1}, uri: uri);
      expect(status, 202);
      expect(stats[StatKey.sent], 1);
      expect(stats[StatKey.failed], 0);
    });

    test('non-2xx → stats.failed, returns the status', () async {
      final stats = Stats();
      final t = Transport(
        token: 'cyi_x',
        stats: stats,
        client: MockClient((_) async => http.Response('{"error":{}}', 422)),
      );
      expect(await t.send({}, uri: uri), 422);
      expect(stats[StatKey.failed], 1);
    });

    test('network error → null, stats.failed + network reason, does NOT throw',
        () async {
      final stats = Stats();
      final t = Transport(
        token: 'cyi_x',
        stats: stats,
        client: MockClient((_) async => throw Exception('boom')),
      );
      expect(await t.send({}, uri: uri), isNull);
      expect(stats[StatKey.failed], 1);
      expect(stats.drops(DropReason.network), 1);
      expect(stats.drops(DropReason.timeout), 0);
    });

    test('timeout → null, stats.failed + timeout reason', () async {
      final stats = Stats();
      final t = Transport(
        token: 'cyi_x',
        stats: stats,
        client: MockClient((_) async => throw TimeoutException('slow')),
      );
      expect(await t.send({}, uri: uri), isNull);
      expect(stats[StatKey.failed], 1);
      expect(stats.drops(DropReason.timeout), 1);
      expect(stats.drops(DropReason.network), 0);
    });

    test('after close(): send skipped, clientClosed reason, network untouched',
        () async {
      final stats = Stats();
      var hits = 0;
      final t = Transport(
        token: 'cyi_x',
        stats: stats,
        client: MockClient((_) async {
          hits++;
          return http.Response('', 202);
        }),
      );
      t.close();
      expect(await t.send({}, uri: uri), isNull);
      expect(hits, 0); // no request went out
      expect(stats.drops(DropReason.clientClosed), 1);
      expect(stats[StatKey.failed], 0); // not a send failure
      expect(stats[StatKey.sent], 0);
    });

    test('sends Bearer/Content-Type/User-Agent headers and a JSON body',
        () async {
      late http.Request captured;
      final t = Transport(
        token: 'cyi_secret',
        stats: Stats(),
        client: MockClient((req) async {
          captured = req;
          return http.Response('', 202);
        }),
      );
      await t.send({'hello': 'world'}, uri: uri);
      expect(captured.method, 'POST');
      expect(captured.headers['Authorization'], 'Bearer cyi_secret');
      expect(captured.headers['Content-Type'], 'application/json');
      expect(captured.headers['User-Agent'], startsWith('closeyourit-dart/'));
      expect(jsonDecode(captured.body), {'hello': 'world'});
    });

    test('follows the redirect preserving the POST and the body', () async {
      final hits = <String>[];
      final t = Transport(
        token: 'cyi_x',
        stats: Stats(),
        client: MockClient((req) async {
          hits.add('${req.method} ${req.url}');
          if (req.url.host == 'www.closeyour.it') {
            return http.Response('', 301,
                headers: {'location': 'https://closeyour.it/redir'});
          }
          return http.Response('', 202);
        }),
      );
      final status = await t.send({'k': 'v'}, uri: uri);
      expect(status, 202);
      expect(hits.length, 2);
      expect(hits.last, 'POST https://closeyour.it/redir');
    });

    test('beyond maxRedirects returns the 3xx', () async {
      final t = Transport(
        token: 'cyi_x',
        stats: Stats(),
        maxRedirects: 1,
        client: MockClient(
          (_) async => http.Response('', 302,
              headers: {'location': 'https://x.it/again'}),
        ),
      );
      expect(await t.send({}, uri: uri), 302);
    });

    test('does NOT re-send the Bearer after a redirect to a different host',
        () async {
      final headersByHost = <String, Map<String, String>>{};
      final t = Transport(
        token: 'cyi_secret',
        stats: Stats(),
        client: MockClient((req) async {
          headersByHost[req.url.host] = req.headers;
          if (req.url.host == 'www.closeyour.it') {
            return http.Response('', 301,
                headers: {'location': 'https://evil.example/collect'});
          }
          return http.Response('', 202);
        }),
      );
      await t.send({'k': 'v'}, uri: uri);
      expect(headersByHost['www.closeyour.it']?['Authorization'],
          'Bearer cyi_secret');
      expect(
          headersByHost['evil.example']?.containsKey('Authorization'), isFalse);
    });

    test('does NOT re-send the Bearer on an https→http downgrade (same host)',
        () async {
      final headersByScheme = <String, Map<String, String>>{};
      final t = Transport(
        token: 'cyi_secret',
        stats: Stats(),
        client: MockClient((req) async {
          headersByScheme[req.url.scheme] = req.headers;
          if (req.url.scheme == 'https') {
            return http.Response('', 301, headers: {
              'location': 'http://www.closeyour.it/api/v1/projects/p/events',
            });
          }
          return http.Response('', 202);
        }),
      );
      await t.send({'k': 'v'}, uri: uri);
      expect(headersByScheme['https']?['Authorization'], 'Bearer cyi_secret');
      expect(headersByScheme['http']?.containsKey('Authorization'), isFalse);
    });

    test('does NOT re-send the Bearer to another port of the same host',
        () async {
      final headersByPort = <int, Map<String, String>>{};
      final t = Transport(
        token: 'cyi_secret',
        stats: Stats(),
        client: MockClient((req) async {
          headersByPort[req.url.port] = req.headers;
          if (req.url.port == 443) {
            return http.Response('', 301, headers: {
              'location': 'https://www.closeyour.it:8443/collect',
            });
          }
          return http.Response('', 202);
        }),
      );
      await t.send({'k': 'v'}, uri: uri);
      expect(headersByPort[443]?['Authorization'], 'Bearer cyi_secret');
      expect(headersByPort[8443]?.containsKey('Authorization'), isFalse);
    });

    test(
        'does NOT re-send the Bearer if the origin is on an explicit port and the redirect is not',
        () async {
      final origin =
          Uri.parse('https://www.closeyour.it:8443/api/v1/projects/p/events');
      final headersByPort = <int, Map<String, String>>{};
      final t = Transport(
        token: 'cyi_secret',
        stats: Stats(),
        client: MockClient((req) async {
          headersByPort[req.url.port] = req.headers;
          if (req.url.port == 8443) {
            return http.Response('', 301, headers: {
              'location': 'https://www.closeyour.it/api/v1/projects/p/events',
            });
          }
          return http.Response('', 202);
        }),
      );
      await t.send({'k': 'v'}, uri: origin);
      expect(headersByPort[8443]?['Authorization'], 'Bearer cyi_secret');
      expect(headersByPort[443]?.containsKey('Authorization'), isFalse);
    });

    test(
        're-sends the Bearer if the explicit port is the default one (www→apex)',
        () async {
      final headersByHost = <String, Map<String, String>>{};
      final t = Transport(
        token: 'cyi_secret',
        stats: Stats(),
        client: MockClient((req) async {
          headersByHost[req.url.host] = req.headers;
          if (req.url.host == 'www.closeyour.it') {
            return http.Response('', 301,
                headers: {'location': 'https://closeyour.it:443/redir'});
          }
          return http.Response('', 202);
        }),
      );
      expect(await t.send({'k': 'v'}, uri: uri), 202);
      expect(headersByHost['www.closeyour.it']?['Authorization'],
          'Bearer cyi_secret');
      expect(
          headersByHost['closeyour.it']?['Authorization'], 'Bearer cyi_secret');
    });

    test('re-sends the Bearer on the http→https upgrade of the same host',
        () async {
      final origin =
          Uri.parse('http://www.closeyour.it/api/v1/projects/p/events');
      final headersByScheme = <String, Map<String, String>>{};
      final t = Transport(
        token: 'cyi_secret',
        stats: Stats(),
        client: MockClient((req) async {
          headersByScheme[req.url.scheme] = req.headers;
          if (req.url.scheme == 'http') {
            return http.Response('', 301, headers: {
              'location': 'https://www.closeyour.it/api/v1/projects/p/events',
            });
          }
          return http.Response('', 202);
        }),
      );
      expect(await t.send({'k': 'v'}, uri: origin), 202);
      expect(headersByScheme['http']?['Authorization'], 'Bearer cyi_secret');
      expect(headersByScheme['https']?['Authorization'], 'Bearer cyi_secret');
    });

    test('trust is measured against the origin, not the previous hop',
        () async {
      final authByHop = <bool>[];
      final t = Transport(
        token: 'cyi_secret',
        stats: Stats(),
        client: MockClient((req) async {
          authByHop.add(req.headers.containsKey('Authorization'));
          switch (authByHop.length) {
            case 1:
              return http.Response('', 301, headers: {
                'location': 'https://www.closeyour.it:8443/collect',
              });
            case 2:
              return http.Response('', 301, headers: {
                'location': 'https://www.closeyour.it/api/v1/projects/p/events',
              });
            default:
              return http.Response('', 202);
          }
        }),
      );
      expect(await t.send({'k': 'v'}, uri: uri), 202);
      // Hops 1 and 3 are the origin authority, 2 is not: the comparison does not
      // move to the previous hop, otherwise the return to the origin
      // would stay without a credential (or the foreign port would receive it).
      expect(authByHop, [true, false, true]);
    });

    test('onDebug receives the R- code + message from the body on non-2xx',
        () async {
      final logs = <String>[];
      final t = Transport(
        token: 'cyi_x',
        stats: Stats(),
        onDebug: logs.add,
        client: MockClient(
          (_) async => http.Response(
            '{"error":{"code":"R422-INGEST-001","message":"Evento malformato"}}',
            422,
          ),
        ),
      );
      await t.send({}, uri: uri);
      expect(logs, hasLength(1));
      expect(logs.first, contains('R422-INGEST-001: Evento malformato'));
    });
  });

  group('Transport.send with a public DSN (publicKey)', () {
    final storeUri = Uri.parse('https://www.closeyour.it/api/p/store');

    test('authenticates with ?sentry_key= and NEVER sends the Bearer',
        () async {
      late http.Request captured;
      final stats = Stats();
      final t = Transport(
        publicKey: 'deadbeef',
        stats: stats,
        client: MockClient((req) async {
          captured = req;
          return http.Response('{"id":"e1"}', 200);
        }),
      );
      final status = await t.send({'hello': 'world'}, uri: storeUri);
      expect(status, 200);
      expect(stats[StatKey.sent], 1);
      expect(captured.url.queryParameters['sentry_key'], 'deadbeef');
      expect(captured.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(captured.body), {'hello': 'world'});
    });

    test('sentry_key is idempotent and keeps the existing query', () async {
      final urls = <Uri>[];
      final t = Transport(
        publicKey: 'deadbeef',
        stats: Stats(),
        client: MockClient((req) async {
          urls.add(req.url);
          return http.Response('', 200);
        }),
      );
      await t.send({},
          uri: storeUri.replace(queryParameters: {
            'x': '1',
            'sentry_key': 'deadbeef',
          }));
      expect(urls.single.queryParameters['x'], '1');
      expect(urls.single.queryParametersAll['sentry_key'], ['deadbeef']);
    });

    test(
        'whitespace-only publicKey → Bearer mode (consistent with usesPublicKey)',
        () async {
      late http.Request captured;
      final t = Transport(
        token: 'cyi_secret',
        publicKey: '   ',
        stats: Stats(),
        client: MockClient((req) async {
          captured = req;
          return http.Response('', 202);
        }),
      );
      await t.send({'k': 'v'}, uri: uri);
      // Whitespace is not a credential: no sentry_key, the Bearer is back.
      expect(captured.url.queryParameters.containsKey('sentry_key'), isFalse);
      expect(captured.headers['Authorization'], 'Bearer cyi_secret');
    });

    test('publicKey with surrounding spaces → trimmed sentry_key, no Bearer',
        () async {
      late http.Request captured;
      final t = Transport(
        publicKey: '  deadbeef  ',
        stats: Stats(),
        client: MockClient((req) async {
          captured = req;
          return http.Response('', 200);
        }),
      );
      await t.send({}, uri: storeUri);
      expect(captured.url.queryParameters['sentry_key'], 'deadbeef');
      expect(captured.headers.containsKey('Authorization'), isFalse);
    });

    test('after a redirect the sentry_key stays and there is no Bearer',
        () async {
      final urlByHost = <String, Uri>{};
      final headersByHost = <String, Map<String, String>>{};
      final t = Transport(
        publicKey: 'deadbeef',
        stats: Stats(),
        client: MockClient((req) async {
          urlByHost[req.url.host] = req.url;
          headersByHost[req.url.host] = req.headers;
          if (req.url.host == 'www.closeyour.it') {
            return http.Response('', 301,
                headers: {'location': 'https://closeyour.it/api/p/store'});
          }
          return http.Response('', 200);
        }),
      );
      final status = await t.send({'k': 'v'}, uri: storeUri);
      expect(status, 200);
      expect(
          urlByHost['closeyour.it']?.queryParameters['sentry_key'], 'deadbeef');
      expect(headersByHost['www.closeyour.it']?.containsKey('Authorization'),
          isFalse);
      expect(
          headersByHost['closeyour.it']?.containsKey('Authorization'), isFalse);
    });
  });

  group('Transport.send with an incomplete response (CYDA-24)', () {
    test('a redirect body timeout ends the send before the monotonic deadline',
        () {
      fakeAsync((async) {
        final stats = Stats();
        final hits = <Uri>[];
        var cancellations = 0;
        final body =
            StreamController<List<int>>(onCancel: () => cancellations++);
        final transport = Transport(
          token: 'cyi_x',
          stats: stats,
          timeout: const Duration(seconds: 5),
          client: _HangingClient((request) async {
            hits.add(request.url);
            return http.StreamedResponse(body.stream, 301,
                headers: {'location': 'https://closeyour.it/redir'});
          }),
        );
        var completed = false;
        int? result;
        transport.send({}, uri: uri).then((status) {
          completed = true;
          result = status;
        });
        async.flushMicrotasks();
        expect(hits, hasLength(1));
        // Timers advance while Stopwatch remains real, reproducing the ordering
        // where a body deadline fires before the next monotonic budget check.
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(completed, isTrue);
        expect(result, isNull);
        expect(hits, hasLength(1));
        expect(cancellations, 1);
        expect(stats.drops(DropReason.timeout), 1);
        expect(stats[StatKey.failed], 1);
        expect(stats.drops(DropReason.network), 0);
        body.close();
        transport.close();
      });
    });

    test('2xx with a body that never ends → returns anyway, sent counted once',
        () async {
      final stats = Stats();
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final t = Transport(
        token: 'cyi_x',
        stats: stats,
        timeout: const Duration(milliseconds: 50),
        client: _HangingClient((_) async =>
            http.StreamedResponse(body.stream, 202)), // headers yes, body never
      );

      expect(await t.send({'k': 'v'}, uri: uri), 202);
      expect(stats[StatKey.sent], 1);
      // The outcome comes from the status, already known: the truncated body does not count it again.
      expect(stats.drops(DropReason.timeout), 0);
      expect(stats[StatKey.failed], 0);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test(
        'a single budget covers headers, body and redirects: the hop past the limit does not go out',
        () async {
      final stats = Stats();
      final hits = <Uri>[];
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final t = Transport(
        token: 'cyi_x',
        stats: stats,
        timeout: const Duration(milliseconds: 50),
        client: _HangingClient((req) async {
          hits.add(req.url);
          // Valid redirect, but the 301 body never ends: it consumes the budget.
          return http.StreamedResponse(body.stream, 301,
              headers: {'location': 'https://closeyour.it/redir'});
        }),
      );

      expect(await t.send({'k': 'v'}, uri: uri), isNull);
      expect(hits,
          hasLength(1)); // the second hop does not go out: budget exhausted
      expect(stats.drops(DropReason.timeout), 1); // counted only once
      expect(stats[StatKey.failed], 1);
      expect(stats[StatKey.sent], 0);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test(
        'non-2xx with a body that never ends → onDebug without detail, no hang',
        () async {
      final stats = Stats();
      final logs = <String>[];
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final t = Transport(
        token: 'cyi_x',
        stats: stats,
        timeout: const Duration(milliseconds: 50),
        onDebug: logs.add,
        client: _HangingClient(
            (_) async => http.StreamedResponse(body.stream, 422)),
      );

      expect(await t.send({}, uri: uri), 422);
      expect(logs.single, 'send failed with status 422'); // unreadable envelope
      expect(stats[StatKey.failed], 1); // a single failure, not two
      expect(stats.drops(DropReason.timeout), 0);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('headers past the timeout → timeout reason, no double counting',
        () async {
      final stats = Stats();
      final t = Transport(
        token: 'cyi_x',
        stats: stats,
        timeout: const Duration(milliseconds: 50),
        client:
            _HangingClient((_) => Completer<http.StreamedResponse>().future),
      );

      expect(await t.send({}, uri: uri), isNull);
      expect(stats.drops(DropReason.timeout), 1);
      expect(stats[StatKey.failed], 1);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}

/// Client that delivers the response decided by the test — including the cases where the
/// headers arrive but the body never ends (or the response never arrives
/// at all): `MockClient` cannot represent them, it always returns an
/// already complete body.
class _HangingClient extends http.BaseClient {
  _HangingClient(this.respond);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    return respond(request);
  }
}
