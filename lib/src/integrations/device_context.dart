import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../client.dart';

/// Device/OS/app contexts collected at init, in Sentry form (`contexts.device`,
/// `contexts.os`, `contexts.app`). Null sections = unavailable on the platform.
@immutable
class DeviceContexts {
  const DeviceContexts({this.device, this.os, this.app});

  final Map<String, Object?>? device;
  final Map<String, Object?>? os;
  final Map<String, Object?>? app;

  /// Release derived from the app context: `app_version+build_number` (pubspec style).
  String? get derivedRelease {
    final appContext = app;
    if (appContext == null) return null;
    final version = appContext['app_version']?.toString();
    if (version == null || version.isEmpty) return null;
    final build = appContext['build_number']?.toString();
    return (build == null || build.isEmpty) ? version : '$version+$build';
  }
}

/// Source of device contexts — injectable in tests (plugins do not run there).
abstract class DeviceContextProvider {
  Future<DeviceContexts> load();
}

/// Real provider: `package_info_plus` (app) + `device_info_plus` (device/OS).
/// Every section is best-effort: missing plugin or unsupported platform → null,
/// never an escaping exception (the client's no-op philosophy).
class PluginDeviceContextProvider implements DeviceContextProvider {
  const PluginDeviceContextProvider();

  @override
  Future<DeviceContexts> load() async {
    final (device, os) = await _deviceAndOs();
    return DeviceContexts(device: device, os: os, app: await _app());
  }

  Future<Map<String, Object?>?> _app() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return {
        'app_version': info.version,
        'build_number': info.buildNumber,
        'bundle_id': info.packageName,
      };
    } on Object {
      return null;
    }
  }

  Future<(Map<String, Object?>?, Map<String, Object?>?)> _deviceAndOs() async {
    try {
      final plugin = DeviceInfoPlugin();
      if (kIsWeb) {
        final browser = await plugin.webBrowserInfo;
        return (
          null,
          {
            'name': browser.browserName.name,
            'version': browser.appVersion ?? ''
          },
        );
      }
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final android = await plugin.androidInfo;
          return (
            {
              'model': android.model,
              'manufacturer': android.manufacturer,
              'simulator': !android.isPhysicalDevice,
            },
            {'name': 'Android', 'version': android.version.release},
          );
        case TargetPlatform.iOS:
          final ios = await plugin.iosInfo;
          return (
            {
              'model': ios.utsname.machine,
              'manufacturer': 'Apple',
              'simulator': !ios.isPhysicalDevice,
            },
            {'name': ios.systemName, 'version': ios.systemVersion},
          );
        case TargetPlatform.macOS:
          final macos = await plugin.macOsInfo;
          return (
            {'model': macos.model, 'manufacturer': 'Apple', 'simulator': false},
            {'name': 'macOS', 'version': macos.osRelease},
          );
        case TargetPlatform.windows:
          final windows = await plugin.windowsInfo;
          return (null, {'name': 'Windows', 'version': windows.displayVersion});
        case TargetPlatform.linux:
          final linux = await plugin.linuxInfo;
          return (null, {'name': linux.name, 'version': linux.version ?? ''});
        case TargetPlatform.fuchsia:
          return (null, null);
      }
    } on Object {
      return (null, null);
    }
  }
}

/// Loads the contexts and installs them in the client scope (every event inherits
/// them by spreading the scope contexts); derives the `version+build` release when
/// the options do not set one. Never throws.
Future<void> installDeviceContext(
  CloseYourItClient client, {
  DeviceContextProvider? provider,
}) async {
  try {
    final contexts =
        await (provider ?? const PluginDeviceContextProvider()).load();

    final device = contexts.device;
    if (device != null) {
      client.setContext('device', Map<String, Object?>.from(device));
    }
    final os = contexts.os;
    if (os != null) client.setContext('os', Map<String, Object?>.from(os));
    final app = contexts.app;
    if (app != null) client.setContext('app', Map<String, Object?>.from(app));

    if (client.options.release == null) {
      client.releaseOverride = contexts.derivedRelease;
    }
  } on Object {
    // Best-effort: without contexts the client stays fully functional.
  }
}
