# Public ingestion evidence (CYRA-973)

The current local candidate enables native logs, `measure()` and the four opt-in
performance subtypes with `publicKey`. Error routing stays on Sentry `/store`;
usage stays server-only. These changes are not included in published 0.8.3.

## Real backend proof

The opt-in `test/integration/public_ingest_test.dart` runs against actual Rails,
PostgreSQL and a Solid Queue worker using the dedicated Labs
`bin/certify-dart-public` runner. No HTTP response is mocked. Existing unit tests
retain their existing HTTP test doubles; they are distinct from this proof.

The VM run `9730000000000006` passed on 2026-10-04, 02:21:05–02:22:09 UTC with
Flutter 3.44.1, Dart 3.12.1 and Darwin arm64. The backend stayed at
`3d206d74fbceb110e467790a42b375d34ec9adaa`, with a dirty tree at both ends.
The sanitized report is `cyi-u29-dart-vm-9730000000000006.json`, SHA-256
`fa38ded9e9b94f202e510a79facc4fa92ff8daa73d727c8ca93a4d8877060076`.

The iOS simulator run `9730000000000008` passed on the same Flutter/Dart/host
tuple, 02:26:45–02:28:05 UTC, using iPhone 17 / iOS 26.5 and Xcode 27.0
(27A266a). Backend identity and dirty states matched the VM run. Its report is
`cyi-u29-dart-ios-9730000000000008.json`, SHA-256
`b6cd2c84a12a57533935309c1449552f7e64dc6190abb7bcd8721c84b71cdefd`.
The four recorded SDK/scenario source hashes remained unchanged during this run.
The temporary app's iOS deployment target was 15.0 to accommodate Xcode 27;
this does not change or certify the package's minimum deployment target.

The Chrome run `9730000000000009` passed at 02:32:08–02:33:05 UTC with Chrome
154.0.8037.97, the same Flutter/Dart/host tuple and backend dirty identity.
Its report is `cyi-u29-dart-chrome-9730000000000009.json`, SHA-256
`3c6989fe4cca1812adc6e61cd76117447343f9402990a6329b6337477d072b04`.
The recorded source hashes stayed unchanged. This uses real browser Fetch and
CORS on native public ingest endpoints. The native-only preliminary health check
is skipped on web because `/up` intentionally has no CORS policy.

The runner proved:

- Zero operations cause no SDK request; one/many operations persist one error,
  three logs and five metrics (one `slow_method` plus all four performance subtypes).
- Actual worker completion, no failed jobs, authenticated private readback and
  sensitive log attribute redaction. The other project remains empty.
- Real 401 for an invalid key, 403 for a read-only key, 413 for oversized native
  metrics and log batches, and 429 from the actual IP rate limiter.
- Public keys cannot read private telemetry or post usages. Opting in to usage
  in the public SDK emits no usage request and persists no usage record.
- Logs/metrics do not automatically retry rejected requests. 401/403 count as
  permanent drops, 413 as too-large drops, and 429 as failed attempts without a
  permanent-drop classification.

The 413 log test is a derived protocol case using the production transport with
1001 records; the normal SDK splits logs into batches of at most 1000. The 413
metric test uses `beforeSend` to exceed the backend's 5 MiB body limit.
The no-Authorization assertion covers `ObservedClient` requests, excluding the
separate derived log transport and the private readback orchestrator. Observing
an empty other project does not replace a full cross-tenant authorization audit.

## Scope and delivery limits

This is **implemented**, not Verified or Released certification: the source tree
is dirty, the package is a local checkout and no registry artifact or compiled
application digest is attested. The VM report records final SDK source hashes;
it does not prove a byte-identical dependency graph or a before/after tree digest.
No Android or physical-device support claim follows from a VM/browser run.
The iOS evidence covers the simulator only. Its supplemental consumer metadata
(`cyi-u29-ios-consumer-metadata.json`, SHA-256
`835990dd8edb688ce7d3b942c2bf36cc1f668f89dde0311df0cf9abcbf515a46`)
records source/configuration hashes after the run, not a compiled-app attestation.

Logs and metrics retain the existing single-attempt delivery behavior. The offline
queue and retry policy apply only to errors. Web clients must use the final
endpoint URL: the official [BrowserClient contract](https://pub.dev/documentation/http/latest/browser_client/BrowserClient-class.html)
does not support manual redirects when `followRedirects` is false.

Earlier slots `.1`/`.3` exposed a wrong test assumption about native request-size
limits; `.4` (VM) and `.2` (Chrome) completed the SDK scenario but failed a runner
readback path. They are not successful certification runs. Slot `.5` failed the
iOS request assertions and is not positive mobile evidence; `.8` adds a direct
Rails health check and passes. The cause of `.5` is not established by that rerun.
Chrome `.7` failed that new health check because of `/up` CORS; `.9` limits the
check to native platforms and completes the unchanged browser ingestion scenario.
