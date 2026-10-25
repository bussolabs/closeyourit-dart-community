import '../client.dart';

/// There are no isolates on web: no-op, no `errorPort`. The signature matches
/// the `_io` variant (conditional import). [client] is ignored.
({void Function() dispose, Object? errorPort}) installIsolateErrorHandler(
        CloseYourItClient client) =>
    (dispose: () {}, errorPort: null);
