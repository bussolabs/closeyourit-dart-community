# CloseYourIt Dart and Flutter SDK

Official Dart and Flutter client for [CloseYourIt](https://closeyour.it), the open source tracker for
errors, logs, uptime and servers. It captures errors, metrics and logs from Flutter apps and sends
them fire-and-forget: it never slows down or crashes the app.

- **Errors**: unhandled exceptions (`FlutterError.onError`, `PlatformDispatcher.onError`, zones) and
  manual `captureException` / `captureMessage`, with offline persistence on disk.
- **Scope and breadcrumbs**: user, tags, context and `trace_id` on every event.
- **Metrics**: `measure()` for block timing; opt-in performance verdicts (`jank`, `rebuild_storm`,
  `slow_external_http`, `repeated_http`).
- **Logs**: `CloseYourIt.log` / `CloseYourIt.logger`, batched and correlated by `trace_id`.
- **Integrations**: Dio interceptor, go_router and Navigator observers, PII scrubbing by default.

## Install

```bash
flutter pub add closeyourit
```

## Quick start

```dart
import 'package:closeyourit/closeyourit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CloseYourIt.init(
    CloseYourItOptions(
      endpointUrl: const String.fromEnvironment('CLOSEYOURIT_ENDPOINT_URL'),
      publicKey: const String.fromEnvironment('CLOSEYOURIT_PUBLIC_KEY'),
      projectId: const String.fromEnvironment('CLOSEYOURIT_PROJECT_ID'),
      environment: const String.fromEnvironment('CLOSEYOURIT_ENVIRONMENT', defaultValue: 'development'),
      release: const String.fromEnvironment('CLOSEYOURIT_RELEASE'),
    ),
    appRunner: () => runApp(const MyApp()),
  );
}
```

Pass the values with `--dart-define`, never hard-coded. A distributed app authenticates with the DSN
public key (`publicKey`): it is not secret and can only send data. The bearer `token` (`cyi_…`) is
server-only and must never ship inside an app.

On a self-hosted installation, `CLOSEYOURIT_ENDPOINT_URL` is the address of your own CloseYourIt.

Full guide: [closeyour.it/docs/sdk-dart](https://closeyour.it/docs/sdk-dart).

## Development

```bash
mise install
flutter pub get
flutter analyze
dart format --output=none --set-exit-if-changed lib test
flutter test
```

## Contributing

Pull requests are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md) and [CLA.md](CLA.md). This
repository is a published copy: accepted changes are applied to the upstream source and come back
here with the next release. Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## License

MIT, see `LICENSE`.
