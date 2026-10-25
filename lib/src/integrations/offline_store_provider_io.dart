import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../file_offline_store.dart';
import '../offline_store.dart';
import '../stats.dart';

/// Default offline store on VM/mobile/desktop: a `closeyourit/pending`
/// subdirectory in the application support dir (path_provider).
///
/// [endpoint] is the queue's reference authority: a record persisted
/// towards a different host is discarded (no telemetry redirection).
/// [onDrop] is the diagnostic sink for the store's internal drops (TTL,
/// eviction, corrupted records) — `Stats.recordDrop` is wired to it (CYDA-13).
///
/// Best-effort: if path_provider is unavailable (unsupported platform,
/// pure tests without plugins) it returns `null` — the client keeps working
/// without persistence. Never throws.
Future<OfflineStore?> createDefaultOfflineStore({
  int maxEvents = 50,
  Uri? endpoint,
  void Function(DropReason reason)? onDrop,
}) async {
  try {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/closeyourit/pending');
    dir.createSync(recursive: true);
    return FileOfflineStore(dir,
        maxEvents: maxEvents, endpoint: endpoint, onDrop: onDrop);
  } on Object {
    return null;
  }
}
