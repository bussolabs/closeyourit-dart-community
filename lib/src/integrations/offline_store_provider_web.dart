import '../offline_store.dart';
import '../stats.dart';

/// There is no filesystem on web: no offline store. The signature matches the
/// `_io` variant (conditional import). [maxEvents], [endpoint] and [onDrop] are
/// ignored.
Future<OfflineStore?> createDefaultOfflineStore({
  int maxEvents = 50,
  Uri? endpoint,
  void Function(DropReason reason)? onDrop,
}) async =>
    null;
