import 'package:closeyourit/src/scrubber.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Scrubber.scrubMap', () {
    test('redacts sensitive keys at the top level', () {
      final out = Scrubber.scrubMap({
        'password': 'hunter2',
        'api_key': 'abc',
        'authorization': 'Bearer x',
        'order_id': 42,
      });
      expect(out['password'], '[FILTERED]');
      expect(out['api_key'], '[FILTERED]');
      expect(out['authorization'], '[FILTERED]');
      expect(out['order_id'], 42);
    });

    test('partial, case-insensitive match on the key name', () {
      final out = Scrubber.scrubMap({
        'userPassword': 'x',
        'CardNumber': '4111',
        'iban': 'IT60X',
        'csrfToken': 't',
      });
      expect(out['userPassword'], '[FILTERED]');
      expect(out['CardNumber'], '[FILTERED]');
      expect(out['iban'], '[FILTERED]');
      expect(out['csrfToken'], '[FILTERED]');
    });

    test('recursively redacts nested maps', () {
      final out = Scrubber.scrubMap({
        'user': {'id': 1, 'token': 'secret-jwt'},
      });
      final user = out['user']! as Map<String, Object?>;
      expect(user['id'], 1);
      expect(user['token'], '[FILTERED]');
    });

    test('traverses lists of maps', () {
      final out = Scrubber.scrubMap({
        'items': [
          {'name': 'a', 'secret': 's1'},
          {'name': 'b', 'cvv': '123'},
        ],
      });
      final items = out['items']! as List<Object?>;
      expect((items[0]! as Map)['name'], 'a');
      expect((items[0]! as Map)['secret'], '[FILTERED]');
      expect((items[1]! as Map)['cvv'], '[FILTERED]');
    });

    test('a sensitive key redacts the whole value (even a map)', () {
      final out = Scrubber.scrubMap({
        'credit_card': {'number': '4111', 'cvv': '123'},
      });
      expect(out['credit_card'], '[FILTERED]');
    });

    test('does not mutate the input map', () {
      final input = <String, Object?>{'token': 'x'};
      Scrubber.scrubMap(input);
      expect(input['token'], 'x');
    });

    test('non-sensitive values pass unchanged', () {
      final out =
          Scrubber.scrubMap({'count': 3, 'name': 'mario', 'active': true});
      expect(out, {'count': 3, 'name': 'mario', 'active': true});
    });
  });

  group('Scrubber.scrubMessage', () {
    test('redacts key=value assignments with a sensitive key', () {
      expect(Scrubber.scrubMessage('login failed password=hunter2'),
          'login failed [FILTERED]');
      expect(Scrubber.scrubMessage('token=abc123'), '[FILTERED]');
    });

    test('also redacts with a ":" separator and spaces', () {
      expect(Scrubber.scrubMessage('api_key = sk_live_42'), '[FILTERED]');
      expect(Scrubber.scrubMessage('Authorization: Bearer_xyz'), '[FILTERED]');
    });

    test(
        'the generic value is redacted entirely, punctuation included '
        '(the password can be made of symbols only)', () {
      expect(Scrubber.scrubMessage('password=hunter2!'), '[FILTERED]');
      expect(Scrubber.scrubMessage(r'password=!!!'), '[FILTERED]');
      expect(Scrubber.scrubMessage('token={"a":"hunter2"}'), '[FILTERED]');
    });

    test('does not touch text without sensitive assignments', () {
      expect(Scrubber.scrubMessage('order 42 created'), 'order 42 created');
      expect(Scrubber.scrubMessage('password reset requested'),
          'password reset requested');
    });
  });

  group('Scrubber — backend PII denylist parity (CYDA-4)', () {
    // The backend PII tokens (SENSITIVE_KEY) missing from the Dart denylist:
    // email phone telephone mobile dob birth passport bearer session pin pan.
    const piiKeys = <String>[
      'email',
      'phone',
      'telephone',
      'mobile',
      'dob',
      'birth',
      'passport',
      'bearer',
      'session',
      'pin',
      'pan',
    ];

    test('redacts all 11 backend PII keys', () {
      final out = Scrubber.scrubMap({
        for (final k in piiKeys) k: 'value-$k',
      });
      for (final k in piiKeys) {
        expect(out[k], '[FILTERED]', reason: 'the key "$k" must be redacted');
      }
    });

    test('redacts realistic columns via partial match', () {
      final out = Scrubber.scrubMap({
        'user_email': 'a@b.com',
        'phone_number': '+391234567',
        'date_of_birth': '1990-01-01',
        'session_id': 'sess_abc',
        'pin_code': '1234',
        'card_pan': '4111111111111111',
        'mobile_number': '3331234567',
        'passport_number': 'YA1234567',
        'bearer_token': 'eyJhbGci',
      });
      out.forEach((key, value) {
        expect(value, '[FILTERED]',
            reason: 'the column "$key" must be redacted');
      });
    });

    test('slow query bind with an email/phone/dob key is redacted (Scenario 1)',
        () {
      final out = Scrubber.scrubMap({
        'email': 'a@b.com',
        'phone': '+391234567',
        'dob': '1990-01-01',
        'order_id': 42,
      });
      expect(out['email'], '[FILTERED]');
      expect(out['phone'], '[FILTERED]');
      expect(out['dob'], '[FILTERED]');
      expect(out['order_id'], 42,
          reason: 'the benign bind must not be touched');
    });

    test('benign keys without tokens stay unchanged', () {
      final out = Scrubber.scrubMap({
        'count': 1,
        'name': 'mario',
        'status': 'ok',
        'title': 'event',
        'active': true,
      });
      expect(out, {
        'count': 1,
        'name': 'mario',
        'status': 'ok',
        'title': 'event',
        'active': true,
      });
    });

    test('scrubMessage redacts assignments with an extended PII key', () {
      expect(Scrubber.scrubMessage('login user email=a@b.com'),
          'login user [FILTERED]');
      expect(Scrubber.scrubMessage('dob=1990-01-01'), '[FILTERED]');
      expect(Scrubber.scrubMessage('session: sess_abc'), '[FILTERED]');
    });
  });

  group('Scrubber.scrubMessage — authentication schemes (CYDA-26)', () {
    // Placeholders, never real credentials: the value is recognisable in the text
    // precisely because it must NOT appear in the transmitted message.
    const bearerValue = 'EXAMPLE_NOT_A_CREDENTIAL';
    const jwtLike = 'eyJhbGciOiJIUzI1NiJ9.EXAMPLE_PAYLOAD.EXAMPLE_SIGNATURE';

    test(
        'access header in textual form: also redacts the value after '
        'Bearer (Scenario 1)', () {
      final out = Scrubber.scrubMessage('Authorization: Bearer $bearerValue');
      expect(out, '[FILTERED]');
      expect(out.contains(bearerValue), isFalse);
    });

    test('redacts the scheme whatever the letter case', () {
      for (final header in <String>[
        'authorization: bearer $bearerValue',
        'AUTHORIZATION: BEARER $bearerValue',
        'Authorization: BeArEr $bearerValue',
      ]) {
        expect(Scrubber.scrubMessage(header), '[FILTERED]', reason: header);
      }
    });

    test('tolerates multiple spaces between key, scheme and credential', () {
      expect(Scrubber.scrubMessage('Authorization:   Bearer   $jwtLike'),
          '[FILTERED]');
    });

    test('also covers the Basic scheme', () {
      const basicValue = 'QWxhZGRpbjpFWEFNUExF==';
      expect(Scrubber.scrubMessage('Authorization: Basic $basicValue'),
          '[FILTERED]');
      expect(Scrubber.scrubMessage('rejected with Basic $basicValue here'),
          'rejected with [FILTERED] here');
    });

    test('redacts the scheme even without a sensitive key in front', () {
      final out =
          Scrubber.scrubMessage('request rejected with Bearer $jwtLike');
      expect(out, 'request rejected with [FILTERED]');
      expect(out.contains('EXAMPLE_PAYLOAD'), isFalse);
    });

    test('authentication header outside the denylist: the whole pair goes away',
        () {
      final out = Scrubber.scrubMessage('X-Auth: Bearer $bearerValue');
      expect(out, '[FILTERED]');
      expect(out.contains(bearerValue), isFalse);
    });

    test(
        'a letters-only Basic credential (base64 without digits) does not pass',
        () {
      // Base64 of `abc:def`: no digits, no symbols. It is the
      // `auth-key: scheme` context that makes it recognisable, not its shape.
      final out = Scrubber.scrubMessage('X-Auth: Basic YWJjOmRlZg');
      expect(out, '[FILTERED]');
      expect(out.contains('YWJjOmRlZg'), isFalse);
    });

    test('Digest: the credential continues past the first space', () {
      final out = Scrubber.scrubMessage(
        'Authorization: Digest username="alice", realm="example", '
        'nonce="EXAMPLE_NONCE_1", response="EXAMPLE_RESPONSE_1"',
      );
      expect(out, '[FILTERED]');
      expect(out.contains('EXAMPLE_NONCE_1'), isFalse);
      expect(out.contains('EXAMPLE_RESPONSE_1'), isFalse);
    });

    test('any key is not enough: the prose after the scheme stays', () {
      expect(Scrubber.scrubMessage('error: Basic authentication failed'),
          'error: Basic authentication failed');
    });

    test('a scheme followed by a word with a full stop is not a credential',
        () {
      expect(Scrubber.scrubMessage('serve Basic required.'),
          'serve Basic required.');
    });

    test('the surrounding non-sensitive text stays readable', () {
      final out = Scrubber.scrubMessage(
          'POST /orders failed (Authorization: Bearer $jwtLike) with status 401');
      expect(out, 'POST /orders failed ([FILTERED]) with status 401');
    });

    test('multi-line message: redacts only the header line', () {
      final out = Scrubber.scrubMessage(
        'request failed\n'
        'Authorization: Bearer $bearerValue\n'
        'Accept: application/json\n'
        'order 42 not created',
      );
      expect(out.contains(bearerValue), isFalse);
      expect(out, contains('request failed'));
      expect(out, contains('Accept: application/json'));
      expect(out, contains('order 42 not created'));
    });

    test('a scheme at the end of a line does not swallow the next line', () {
      final out =
          Scrubber.scrubMessage('expected scheme Bearer\nmario is here');
      expect(out, contains('mario is here'));
    });

    test('normal prose with the same words stays unchanged', () {
      for (final text in <String>[
        'bearer of bad news',
        'Basic auth required',
        'digest computed for the payload',
        'use the basic method to start',
      ]) {
        expect(Scrubber.scrubMessage(text), text, reason: text);
      }
    });

    test('a long message without credentials costs linear, not quadratic time',
        () {
      // 64 KB without `auth` in it: with unbounded quantifiers around
      // `auth` this backtracking blocked the thread reporting the error for
      // tens of seconds. Generous budget: it measures the order of magnitude,
      // not the speed of the machine.
      final longMessage = 'Bearer ${'a' * 64000}';
      final stopwatch = Stopwatch()..start();
      final out = Scrubber.scrubMessage(longMessage);
      stopwatch.stop();
      expect(out, longMessage, reason: 'no credential: text unchanged');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('redacted form identical to the other SDKs: a single [FILTERED]', () {
      final out = Scrubber.scrubMessage('Authorization: Bearer $bearerValue');
      expect(out, Scrubber.filtered);
      expect('[FILTERED]'.allMatches(out).length, 1,
          reason: 'scheme and credential collapse into a single placeholder');
    });
  });

  group('Scrubber.sanitizeUri (CYDA-8)', () {
    test('default (sendPii false): removes the query entirely', () {
      final uri = Uri.parse(
          'https://api.x.it/orders?token=abc&email=a@b.it&code=123456');
      expect(Scrubber.sanitizeUri(uri), 'https://api.x.it/orders');
    });

    test('default: password and one-time code do not leak', () {
      final uri =
          Uri.parse('https://api.x.it/login?password=hunter2&otp_code=987654');
      final out = Scrubber.sanitizeUri(uri);
      expect(out, 'https://api.x.it/login');
      expect(out.contains('hunter2'), isFalse);
      expect(out.contains('987654'), isFalse);
    });

    test('sendPii true: keeps benign parameters, redacts sensitive ones', () {
      final uri =
          Uri.parse('https://api.x.it/orders?token=abc&page=2&sort=asc');
      final out = Scrubber.sanitizeUri(uri, sendPii: true);
      expect(out, 'https://api.x.it/orders?token=[FILTERED]&page=2&sort=asc');
    });

    test('sendPii true: redacts email/bearer/session via partial match', () {
      final uri = Uri.parse(
          'https://api.x.it/u?user_email=a@b.it&bearer_token=x&session_id=s&q=hi');
      final out = Scrubber.sanitizeUri(uri, sendPii: true);
      expect(out, contains('user_email=[FILTERED]'));
      expect(out, contains('bearer_token=[FILTERED]'));
      expect(out, contains('session_id=[FILTERED]'));
      expect(out, contains('q=hi'));
      expect(out.contains('a@b.it'), isFalse);
    });

    test('sendPii true: redacts every occurrence of a repeated sensitive key',
        () {
      final uri = Uri.parse('https://api.x.it/x?token=a&token=b&page=1');
      final out = Scrubber.sanitizeUri(uri, sendPii: true);
      expect(out, 'https://api.x.it/x?token=[FILTERED]&page=1');
    });

    test('sendPii true without a query: no dangling question mark', () {
      final uri = Uri.parse('https://api.x.it/health');
      expect(
          Scrubber.sanitizeUri(uri, sendPii: true), 'https://api.x.it/health');
    });

    test('always excludes userInfo and fragment (credentials in the URL)', () {
      final uri = Uri.parse('https://user:secretpass@api.x.it/x?a=1#frag');
      expect(Scrubber.sanitizeUri(uri), 'https://api.x.it/x');
      final withPii = Scrubber.sanitizeUri(uri, sendPii: true);
      expect(withPii, 'https://api.x.it/x?a=1');
      expect(withPii.contains('secretpass'), isFalse);
      expect(withPii.contains('frag'), isFalse);
    });

    test('relative/malformed URI: keeps only the path', () {
      expect(Scrubber.sanitizeUri(Uri.parse('/local/path?token=x')),
          '/local/path');
      expect(
          Scrubber.sanitizeUri(Uri.parse('/local/path?token=x'), sendPii: true),
          '/local/path?token=[FILTERED]');
    });

    test('keeps the non-standard port in the origin', () {
      final uri = Uri.parse('https://api.x.it:8443/orders?token=x');
      expect(Scrubber.sanitizeUri(uri), 'https://api.x.it:8443/orders');
      expect(Scrubber.sanitizeUri(uri, sendPii: true),
          'https://api.x.it:8443/orders?token=[FILTERED]');
    });

    test('omits the scheme default port', () {
      expect(Scrubber.sanitizeUri(Uri.parse('https://api.x.it:443/x')),
          'https://api.x.it/x');
      expect(Scrubber.sanitizeUri(Uri.parse('http://api.x.it:80/x')),
          'http://api.x.it/x');
    });

    test(
        'sendPii true: benign values with special characters are re-encoded '
        '(no spurious parameters)', () {
      final uri =
          Uri.parse('https://api.x.it/s?q=a%26b%3Dc&next=%2Fhome%3Fx%3D1');
      final out = Scrubber.sanitizeUri(uri, sendPii: true);
      final reparsed = Uri.parse(out);
      expect(reparsed.queryParameters['q'], 'a&b=c');
      expect(reparsed.queryParameters['next'], '/home?x=1');
      expect(reparsed.queryParametersAll.keys.toList(), ['q', 'next']);
    });
  });
}
