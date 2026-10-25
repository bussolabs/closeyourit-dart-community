/// Builder of the default offline store, resolved per platform via
/// conditional import: on VM/mobile/desktop (`dart.library.io`) it uses the
/// filesystem (path_provider + [FileOfflineStore]); on web, where there is no
/// filesystem, it always returns `null` (no persistence, the client stays
/// fully functional in memory).
///
/// Keeping `dart:io` and `path_provider` confined to the `_io` variant is what
/// keeps the package compilable on web.
library;

export 'offline_store_provider_web.dart'
    if (dart.library.io) 'offline_store_provider_io.dart';
