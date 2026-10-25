# BUILD — closeyourit-dart

Tracking di build a microfasi (TDD). Specchio del gem `closeyourit-ruby`. Contratto wire:
`POST {endpointUrl}/api/v1/projects/{projectId}/{events,metrics,logs}`, `Authorization: Bearer cyi_…`,
risposta `202 {data:…}`. Per le app distribuite la public key abilita anche logs/metrics
con `?sentry_key=`, senza Bearer; errori sul drop-in `/api/{projectId}/store`. Usages resta
server-only. Fire-and-forget, scrubbing PII opt-out.

DoD globale per ogni fase: `dart format` pulito · `flutter analyze` 0 issue · test verdi · coverage ≥90% line sul nuovo codice.

| # | Fase | Stato | DoD |
|---|------|-------|-----|
| 1 | Scaffold (pubspec, lints, mise, barrel, docs, git) | ✅ | pub get + analyze puliti, test identità verde |
| 2 | Configuration (`CloseYourItOptions`, enabled/validate) | ✅ | no http in prod, blank→disabled, soglie |
| 3 | Scrubber (denylist PII + beforeSend) | ✅ | redazione ricorsiva |
| 4 | Scope + breadcrumbs (ring buffer, trace_id) | ✅ | toEventHash chiavi non vuote, user solo id |
| 5 | StackFrames (StackTrace → frames Sentry) | ✅ | ordine + in_app |
| 6 | Events toJson (error/message/metric/log) | ✅ | campi ESATTI contratto |
| 7 | Transport + worker (http, Bearer, fire-and-forget) | ✅ | mai throw, redirect ≤2, drop overflow |
| 8 | Façade (init/capture/log/logger/measure/scope) | ✅ | dedup + sampling |
| 9 | LogBuffer batching (50/5s/close+lifecycle) | ✅ | FakeAsync |
| 10 | Integrazioni Flutter (appRunner/Dio/navigator) | ✅ | unhandled capture, mai Authorization |
| 11 | Docs + example/ | ✅ | README + app esempio |
| 12 | CI + release (pub.dev OIDC su tag) | ✅ | ci.yml + release.yml scritti |

> Stato: 114 test verdi · `flutter analyze` 0 issue · coverage **98%** line.

## Passi manuali residui (outward — richiedono conferma)

1. **Creare il repo GitHub** `bussolabs/closeyourit-dart` (privato), poi push del branch `main`.
2. **Descrizione + topics** (rules/github.md):
   `gh repo edit bussolabs/closeyourit-dart --description "[Flutter] CloseYourIt — client Dart/Flutter (errori, metriche, logs) verso il backend di osservabilità interno. Mirror di closeyourit-ruby. Pubblicato su pub.dev." --add-topic flutter,dart,observability,error-tracking,logging,closeyourit`
3. **pub.dev trusted publisher**: su pub.dev → package `closeyourit` → Admin → Automated publishing →
   GitHub Actions, repo `bussolabs/closeyourit-dart`, tag pattern `v{{version}}`.
4. **Prima release**: `git tag v0.1.0 && git push --tags` (dopo fetch+push di `main` in fast-forward,
   vedi gotcha rilascio package: il tag pubblica anche se `main` è rifiutato).

## Note di build

- Metriche: solo `kind: slow_method` (niente SQL in Flutter). `slow_query` N/A.
- trace_id: scope globale settabile + per-request via interceptor Dio (Zone stretch).
- Dep runtime minimali: `http` (transport), `stack_trace`, `dio` (interceptor), `meta`. No freezed.
- Versioning: libreria → semver da 0.1.0 (NON lo schema store di rules/flutter/versioning.md).
