import 'package:closeyourit/closeyourit.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

/// Minimal integration example of the CloseYourIt client.
///
/// The `CLOSEYOURIT_*` values come via `--dart-define`, e.g.:
/// ```
/// flutter run \
///   --dart-define=CLOSEYOURIT_ENDPOINT_URL=https://app.closeyour.it \
///   --dart-define=CLOSEYOURIT_PUBLIC_KEY=<dsn public key> \
///   --dart-define=CLOSEYOURIT_PROJECT_ID=...
/// ```
///
/// A distributed app uses the `publicKey` (DSN, not secret): no server-side
/// Bearer in the package. See the README for token vs publicKey.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await CloseYourIt.init(
    CloseYourItOptions(
      endpointUrl: const String.fromEnvironment('CLOSEYOURIT_ENDPOINT_URL'),
      publicKey: const String.fromEnvironment('CLOSEYOURIT_PUBLIC_KEY'),
      projectId: const String.fromEnvironment('CLOSEYOURIT_PROJECT_ID'),
      environment: const String.fromEnvironment(
        'CLOSEYOURIT_ENVIRONMENT',
        defaultValue: 'development',
      ),
      release: const String.fromEnvironment('CLOSEYOURIT_RELEASE'),
      // Opt-in automatic breadcrumbs (synthetic, no PII): network, lifecycle
      // and recent interactions put in context an error that happens shortly after.
      captureLifecycleBreadcrumbs: true,
      captureConnectivityBreadcrumbs: true,
      captureTapBreadcrumbs: true,
    ),
    appRunner: () => runApp(const ExampleApp()),
  );
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CloseYourIt Example',
      navigatorObservers: [CloseYourItNavigatorObserver()],
      // Enables tap breadcrumbs (captureTapBreadcrumbs): records the type and
      // route of the interaction, never the text or the data of the tapped widget.
      builder: (context, child) =>
          CloseYourItUserInteraction(child: child ?? const SizedBox()),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Dio get _dio => Dio()..interceptors.add(CloseYourItDioInterceptor());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CloseYourIt')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 12,
          children: [
            Text('Abilitato: ${CloseYourIt.isEnabled}'),
            ElevatedButton(
              onPressed: () {
                CloseYourIt.setUser(id: 'demo-7');
                CloseYourIt.addBreadcrumb(
                    message: 'tap: capture error', category: 'ui');
                CloseYourIt.captureException(
                  StateError('sample error'),
                  stackTrace: StackTrace.current,
                  handled: true,
                );
              },
              child: const Text('Cattura un errore'),
            ),
            ElevatedButton(
              onPressed: () => CloseYourIt.logger.info(
                'button pressed',
                attributes: {'screen': 'home'},
              ),
              child: const Text('Invia un log'),
            ),
            ElevatedButton(
              onPressed: () => CloseYourIt.measure(
                'demo.work',
                () async =>
                    Future<void>.delayed(const Duration(milliseconds: 300)),
              ),
              child: const Text('Misura una metrica'),
            ),
            ElevatedButton(
              onPressed: () async {
                try {
                  await _dio.get<dynamic>('https://httpbin.org/status/500');
                } on DioException {
                  // The interceptor has already captured the 5xx error.
                }
              },
              child: const Text('Chiamata HTTP che fallisce'),
            ),
          ],
        ),
      ),
    );
  }
}
