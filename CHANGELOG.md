# Changelog

Tutte le modifiche rilevanti sono documentate qui. Formato [Keep a Changelog](https://keepachangelog.com/it/1.1.0/),
versioni [SemVer](https://semver.org/lang/it/).

## [Unreleased]

## [0.10.1] - 2026-10-07

### Corretto

- **Nessun cambiamento funzionale.** Riallinea il README alla versione pubblicata; la 0.10.0 non è stata pubblicata su pub.dev e questa versione ne include le correzioni.

## [0.10.0] - 2026-10-07

### Sicurezza

- **Token mai in chiaro fuori da localhost.** Con un `token`, un endpoint `http://` è rifiutato in ogni ambiente, non solo in `production`; restano ammessi `localhost`, `127.0.0.1` e `::1`. Il README avvisa che la coda offline su Android può finire nell'Auto Backup.

## [0.9.3] - 2026-10-04

### Corretto

- **Build Android indipendenti.** Ogni job usa una propria directory SDK, evitando che installazioni simultanee rimuovano strumenti in uso. La 0.9.2 non è arrivata su pub.dev; questa versione include le funzionalità e le correzioni precedenti.

## [0.9.2] - 2026-10-04

Non pubblicata su pub.dev: due build Android concorrenti hanno interferito durante l’installazione degli strumenti condivisi.

### Corretto

- **Redirect entro il limite di invio.** Quando il body di un redirect scade, non parte una seconda richiesta. Le versioni 0.9.0 e 0.9.1 non sono arrivate su pub.dev; questa versione include log e metriche con chiave pubblica.

## [0.9.1] - 2026-10-04

Non pubblicata su pub.dev: il controllo sul limite dei redirect ha rilevato una seconda richiesta dopo la scadenza del body.

### Corretto

- **Pubblicazione isolata per job.** La configurazione Pub dei runner Linux resta temporanea, evitando credenziali orfane condivise. La 0.9.0 non è stata pubblicata su pub.dev; questa versione contiene le stesse funzionalità.

## [0.9.0] - 2026-10-04

Non pubblicata su pub.dev: il controllo delle dipendenze è stato bloccato dalla configurazione persistente del runner.

### Aggiunto

- **Log e metriche con chiave pubblica.** Le app distribuite possono inviare log, misure e verdetti performance con la DSN public key, senza includere un Bearer. La telemetria d'uso resta riservata al server.

## [0.8.3] - 2026-10-01

### Corretto

- **Pubblicazione riparata.** La 0.8.2 non è arrivata su pub.dev: questa versione contiene le stesse modifiche.

## [0.8.2] - 2026-10-01

### Modificato

- **Manutenzione interna.** Commenti e test sono in inglese e i controlli automatici seguono le nuove regole dei rilasci. Per chi usa la libreria non cambia niente.

## [0.8.1] - 2026-09-07

### Corretto

- **Le credenziali dentro un messaggio non escono più in chiaro** — se un errore o un messaggio
  riportava un header di accesso, la parte dopo `Bearer` restava leggibile. Ora tipo e credenziale
  spariscono insieme, e anche i messaggi inviati a mano passano dal filtro.

- **La chiave del progetto non finisce più a un servizio diverso** — bastava che l'indirizzo
  configurato rimandasse a un'altra porta dello stesso nome per consegnargliela. Ora la chiave
  segue solo l'indirizzo esatto configurato.

- **Un server che risponde a metà non blocca più l'app** — bastava che smettesse di rispondere a
  invio iniziato: le segnalazioni successive venivano buttate e la chiusura poteva non finire mai.
  Ora ogni invio ha un tempo massimo e la chiusura termina sempre.

## [0.8.0] - 2026-09-03

### Aggiunto

- **Ora si vede quali parti dell'app vengono davvero usate** — prima quella pagina restava vuota per
  chi usa questa libreria. Basta segnare i punti che interessano e ogni cinque minuti parte un solo
  invio con l'elenco. Va acceso a mano e richiede la chiave da server.

### Corretto

- **Il numero del rilascio e quello dentro il pacchetto non possono più divergere** — non li
  confrontava nessuno: il rilascio poteva chiamarsi in un modo e pubblicare un altro numero, e
  finire verde lo stesso. Se quel numero era già uscito, il magazzino rifiutava il rilascio buono e
  il lavoro restava a metà: l'etichetta creata, niente pubblicato. Adesso il rilascio si ferma prima
  di pubblicare, e dice quale dei due va aggiornato. Si ferma anche su un'etichetta di prova, che
  qui non ha dove andare: il magazzino riceve solo versioni definitive.

### Documentazione

- **La presentazione non promette più di fare tutto quello che fanno le altre librerie** — alcune
  funzioni esistono solo qui, altre solo altrove. Ora rimanda alla tabella unica che dice, funzione
  per funzione, cosa c'è in quale libreria.

## [0.7.2] - 2026-08-16

### Corretto

- **La pubblicazione si fermava sulla versione stessa** — la 0.7.1 non è mai arrivata su pub.dev:
  tre test tenevano il numero di versione scritto a mano dentro l'asserzione, quindi ogni rilascio
  li faceva cadere e la pubblicazione si fermava prima di partire. Il quarto controllo, quello che
  confronta il README col pubspec, era corretto e diceva il vero: il README consigliava ancora la
  versione precedente. Ora la versione attesa si legge dal pubspec e dalla costante dell'SDK, e il
  README è allineato — un rilascio pulito passa da solo, e una versione dimenticata cade qui invece
  che addosso a chi riceve gli eventi.

## [0.7.1] - 2026-08-16

### Sicurezza

- **Action CI pinnate al commit e permessi minimi** — CYDA-17. Ogni action di terze parti dei
  workflow (`actions/checkout`, `subosito/flutter-action`, `actions/setup-java`,
  `android-actions/setup-android`) è fissata al **commit SHA** con la versione a commento, invece
  che a un tag mobile: un tag può essere ripuntato da chi controlla il repository dell'action, e
  quel codice girerebbe sul runner che pubblica su pub.dev. I tre workflow dichiarano
  `permissions: contents: read` come base, e il **token OIDC (`id-token: write`) resta solo sul job
  che pubblica**; la pubblicazione continua a non custodire alcun segreto pub.dev. `verify.yml`
  dichiara i propri permessi perché in un workflow riusato valgono quelli del chiamato (CYDA-20).
  Nel job che pubblica la cache di `flutter-action` è **disattivata**: è una composite action e con
  la cache attiva eseguirebbe `actions/cache@v5`, un tag mobile che il pin non copre, proprio nel
  job con `id-token: write`. Le action salgono anche alle major correnti (`checkout` v7,
  `setup-java` v5, `setup-android` v4): il pool self-hosted gira runner 2.336.0 e i log di CI
  segnalavano già `setup-java v4 is deprecated and will no longer receive updates`.

### Cambiato

- **Aggiornamenti di dipendenze automatizzati** — CYDA-17. Nuovo `.github/dependabot.yml`: bump
  settimanali raggruppati per le action (con lo SHA e il commento di versione riscritti) e per i
  package pub della libreria e dell'app di esempio. Ogni PR passa dalla matrice di `verify.yml`
  (analisi, test, coverage ≥90%, build Android/iOS/web su Flutter minimo e corrente) prima del
  merge, così un pin non invecchia in silenzio e un bump non entra senza prove.
- **Audit dipendenze pub**: tutte le dipendenze dirette sono già alla massima versione risolvibile
  (`dio` 5.11.0). `meta` **resta a `^1.15.0` di proposito**: il Flutter SDK lo pinna a una versione
  esatta (1.17.0 su 3.38.1, 1.18.0 su 3.44.1), quindi chiedere `^1.19.0` renderebbe il package
  irrisolvibile sul Flutter minimo supportato invece che più aggiornato — Dependabot lo ignora.
  Nuovo `test/ci_workflows_test.dart` blinda pin, permessi, OIDC senza segreti, automazione e la
  coerenza fra `pubspec.yaml`, `mise.toml` e la matrice di build. Nuove dev dependencies: `yaml`,
  `pub_semver`.

## [0.7.0] - 2026-08-06

### Aggiunto

- **Propagazione del W3C Trace Context nelle richieste Dio** — CYDA-16. L'interceptor può iniettare
  `traceparent`/`tracestate` W3C nelle chiamate HTTP uscenti, correlando la chiamata mobile con i
  log del backend end-to-end. È **opt-in** (`propagateTraceContext`, default OFF) e **limitata da
  allowlist**: gli header partono **solo** verso gli host in `tracePropagationAllowlist` (match
  esatto o per sottodominio) — host esterni esclusi. Il `traceparent` riusa il `trace_id` di
  correlazione dello scope (già conforme W3C) e genera un `parent-id` nuovo a ogni richiesta, così
  chiamate concorrenti non condividono lo span; una richiesta con un `traceparent` valido a monte ne
  continua il trace (nested request), uno malformato viene scartato. `tracestate` e `baggage` sono
  filtrati con la denylist PII dello `Scrubber` prima di partire: nessuna informazione interna verso
  destinazioni non autorizzate. Nuove opzioni: `propagateTraceContext`, `tracePropagationAllowlist`.

- **Breadcrumb di connettività, lifecycle e tap** — CYDA-15. Tre sorgenti automatiche aggiungono
  breadcrumb **sintetici** che contestualizzano un crash o un rallentamento avvenuto subito dopo un
  cambio di rete, un passaggio in background o un'interazione: `captureLifecycleBreadcrumbs`
  (`data.state`), `captureConnectivityBreadcrumbs` (`data.connectivity` = solo il tipo di rete, via
  `connectivity_plus`) e `captureTapBreadcrumbs` (tipo + rotta, con `CloseYourItUserInteraction`
  attorno all'app). Tutte **opt-in** (default OFF), **minimali** e **prive di PII**: mai il testo
  digitato né i dati del widget toccato. I toggle di rete rapidi e i tap a raffica sono soppressi da
  `breadcrumbThrottleMs` (default 500 ms, ring buffer già esistente); connettività e lifecycle sono
  deduplicati sugli stati identici. Il flush dei log in background resta attivo a prescindere dai
  flag. Piattaforma senza plugin di connettività o permessi negati → nessun breadcrumb, mai un crash
  (filosofia no-op del client). Nuovi export: `CloseYourItConnectivityObserver`,
  `CloseYourItUserInteraction`, `CloseYourItConnectivity`, `ConnectivitySource`,
  `PluginConnectivitySource`.

- **Diagnostica di invii e scarti visibile e strutturata** — CYDA-13. Uno sviluppatore capisce se
  un evento è stato inviato, persistito, ritentato o eliminato — e **perché** — senza leggere i
  file interni e senza generare nuova telemetria. `Stats` è esteso con i **motivi strutturati**
  di scarto (`DropReason`), uno **snapshot immutabile** (`CloseYourIt.diagnostics`) che affianca
  ai contatori di flusso i motivi, e una **callback opzionale** `CloseYourItOptions.onDiagnostic`
  (in-process, nessun evento ricorsivo, un'eccezione al suo interno è assorbita). I motivi coprono
  transport, worker e offline store — punti finora muti: `sampled`, `beforeSend`, `excluded`,
  `duplicate`, `queueFull`, `timeout`, `network`, `clientClosed`, `permanentReject`, `tooLarge`
  (413, oltre il budget payload lato server — CYRA-112), `maxAttempts`, `expired` (TTL), `evicted`
  (capienza), `storeCorrupted`. La semantica storica di `dropped`/`failed`/`discarded` è
  preservata (i motivi corrispondenti li aggregano); lo snapshot porta solo enum e interi, mai dati
  sensibili.

### Cambiato

- **Versione minima di Flutter dichiarata correttamente a 3.38.1** — CYDA-14. Il vincolo `flutter`
  del package passa da `>=3.10.0` a `>=3.38.1`, il minimo realmente imposto dalle dipendenze
  (`device_info_plus`, `package_info_plus`, `path_provider`): su versioni inferiori `pub get` non
  risolveva. La CI ora verifica analisi, test e **build dell'app di esempio per Android, iOS e web**
  sul Flutter minimo e su quello stabile corrente, con `dart pub publish --dry-run` come gate: un
  package che non compila su una piattaforma supportata non raggiunge la pubblicazione.

## [0.6.0] - 2026-08-01

### Aggiunto

- **DSN public key per le app client** — CYDA-7. `CloseYourItOptions.publicKey`: credenziale di solo
  ingest (esadecimale, **non segreta**) per le app Flutter distribuite. Gli errori/messaggi vanno al
  drop-in Sentry `POST /api/{projectId}/store` con `?sentry_key=` (fuori da `/api/v1`), **senza mai
  includere un `Authorization: Bearer` nel pacchetto** — la chiave estratta non legge né amministra il
  progetto. La chiave viaggia in query (CORS-safe), in parità col client JS.

### Modificato

- **`CloseYourItOptions.token` ora opzionale** — CYDA-7. Serve `publicKey` **oppure** `token`; senza
  nessuna delle due il client resta no-op (`disabledReason: credenziale mancante`). Il Bearer `cyi_…`
  resta **server-only** (porta anche la lettura della telemetria) ed è ignorato quando `publicKey` è
  impostata. Con la sola `publicKey` metriche e logs **non vengono inviati**: il backend espone la DSN
  pubblica solo per il canale eventi e rifiuta la chiave sui path `/api/v1` (401).

### Aggiunto (coda offline)

- **Scadenza, tetto tentativi e backoff con jitter sulla coda offline** — CYDA-11. Gli eventi molto
  vecchi o ripetutamente non consegnabili non restano più per sempre su disco né vengono ritentati tutti
  allo stesso avvio. Nuovo schema record v2 (`attempt_count`, `next_attempt_at`, con migrazione in
  lettura dei record legacy), `OfflineRetryPolicy` con TTL, tetto tentativi e backoff esponenziale con
  jitter deterministico (FNV-1a, quindi riproducibile e scaglionato tra eventi). `readAll` pianifica solo
  gli eventi dovuti e non scaduti: gli scaduti vengono eliminati, quelli in backoff restano per un avvio
  successivo — niente raffica alla riapertura.

### Corretto

- **Niente più query e segreti negli URL registrati** — CYDA-8. L'interceptor Dio registrava l'URL intero
  in breadcrumb, request context e dettagli d'errore, esponendo password, token, email o codici temporanei
  presenti nella query **anche con `sendPii` disattivato**. Ora `Scrubber.sanitizeUri` conserva per
  default solo schema, host e path; con `sendPii` la query resta ma i parametri sensibili sono redatti
  riusando la denylist condivisa. `userInfo` e fragment sono sempre esclusi. Robusto su URI relativi o
  malformati. La porta viene preservata e i valori di query ri-encodati.
- **Richieste Dio concorrenti non si scambiano più il contesto** — CYDA-9. `onRequest` non muta più lo
  scope globale condiviso: salva uno snapshot del request context in `RequestOptions.extra`, che `onError`
  passa a `captureException` solo se **quella** richiesta fallisce. Prima, più chiamate in parallelo si
  scambiavano URL, metodo e header, e lo scope conservava richieste vecchie.
- **I rifiuti permanenti escono dalla coda offline** — CYDA-10. Un evento persistito veniva rimosso solo
  su risposta `2xx`: un `400`/`401`/`403`/`413` restava su disco e veniva ritentato a ogni avvio,
  occupando la coda per sempre. Ora rete, `408`, `425`, `429` e `5xx` restano ritentabili (con `429` che
  preserva l'attesa `Retry-After`), tutto il resto viene scartato. Lo scarto è diagnosticabile via il
  nuovo contatore `discarded` e un log in `debug`.
- **Una seconda `init` non duplica più i gestori** — CYDA-12. Prima installava un secondo set di gestori
  errore, observer di lifecycle e frame callback senza chiudere il client precedente: gli errori venivano
  catturati due volte e vecchio client, transport e observer restavano orfani. Ora `init` chiude in
  sicurezza il client attivo prima di sostituirlo, e `close` azzera il riferimento anche in caso di errore.

### Documentazione

- **README allineato alla versione pubblicata** — CYDA-18. Consigliava `^0.3.0` mentre il pacchetto era
  già avanti: una nuova app che seguiva la documentazione partiva da una minor priva delle correzioni di
  privacy. Un test blinda ora la coerenza fra README e `pubspec.yaml`.

## [0.5.0] - 2026-07-10

### Aggiunto

- **Persistenza crash offline (pattern Crashlytics)** — CYDA-5. Gli eventi errore
  (`captureException`/`captureMessage`) vengono scritti **sincronamente su disco** prima dell'invio e
  rimossi solo alla conferma `2xx`: un crash che chiude l'app (o un periodo offline) non li perde più,
  vengono **rispediti al prossimo avvio** (`replayPending`, chiamato da `init`). Store su file
  (path_provider), un file JSON per evento; il payload su disco è **sempre scrubato** (nessun segreto
  in chiaro). Nuove opzioni `persistOffline` (default `true`) e `maxPersistedEvents` (default `50`,
  sfratto dei più vecchi). Su web (nessun filesystem) la persistenza è assente e il client resta
  pienamente funzionante in-memory. Store iniettabile via `init(offlineStore: …)` per i test.
- **Backstop errori isolate** — `init` aggancia `Isolate.current.addErrorListener` per gli errori non
  gestiti dell'isolate corrente (root) che sfuggono a `FlutterError`/`PlatformDispatcher`, catturati
  come `IsolateError` `fatal` (persistiti come gli altri errori). Per gli **isolate spawnati**
  (`Isolate.spawn`) è esposto `CloseYourIt.isolateErrorPort` (`SendPort`) da passare come `onError`
  allo spawn. `dart:isolate` è confinato dietro conditional import → nessun impatto sulla build web.
- Nuovi contatori diagnostici `stats`: `persisted` (eventi scritti su disco) e `replayed` (eventi
  ripresi dal disco al boot).
- **Opzione `debug`** su `CloseYourItOptions`: con `debug: true` i fallimenti d'invio del transport
  vengono loggati via `debugPrint` (status + codice `R…` + messaggio dall'envelope backend), invece
  di restare muti (prima diagnosticabili solo con un proxy HTTP).

### Corretto

- **Parità PII scrubber (denylist backend)** — CYDA-4. La denylist dello `Scrubber` client
  ora include i token PII del backend (`SENSITIVE_KEY`) — `email phone telephone
  mobile dob birth passport bearer session pin pan` — oltre a quelli già presenti.
  Prima i bind di query/metodi lenti (`capture_query_bindings`) su colonne
  `email`/`phone`/`dob` non venivano redatti e finivano nel pannello Parametri della
  metric-group. Match per sottostringa (over-redaction privacy-by-default), allineato
  1:1 alla gem Ruby. `sensitiveKey` e la regex dei messaggi condividono ora un'unica
  sorgente di token, così non possono più divergere.
- **Sicurezza redirect**: il `Bearer` (segreto d'ingest) non viene più ri-inviato dopo un redirect
  verso un host diverso, né su un downgrade `https→http` — solo stesso host (o variante `www`) e
  schema non degradato. Evita di consegnare il token a un endpoint non fidato.
- **DX misconfig**: `init()` con config incompleta (token/projectId mancante) emette ora un
  `debugPrint` esplicito invece di restare un no-op silenzioso (non avvisa se `enabled: false`).
- **Correlazione log↔errori su mobile (auto-trace)** — CYDA-6. Il `trace_id` non era **mai** popolato
  automaticamente su Dart (a differenza del client JS per-pagina e del gem Ruby per-richiesta): senza
  una `setTraceId` manuale ogni evento partiva con `trace_id` assente e log/errori/metriche di uno
  stesso tap erano **impossibili da correlare**. Ora lo `Scope` **auto-popola** il `trace_id` per
  unità logica — `ensureTraceId()` ne genera uno (32 hex) al primo evento e lo condivide con tutti
  quelli successivi (stesso tap/schermata), mentre il `CloseYourItNavigatorObserver` lo **ruota a
  ogni navigazione** (`rotateTraceId()`, parità col "per-pagina" di JS; su `didRemove` ruota solo se
  viene rimossa la schermata **in cima** — la route sotto torna visibile — non per la rimozione di una
  route sepolta come in `pushAndRemoveUntil`). Una
  `setTraceId` esplicita **vince e sopravvive alla navigazione** (il flusso correlato a mano, es. un
  checkout multi-schermata, non viene ruotato finché non lo si rilascia con
  `setTraceId(null)`/`clearScope`); senza pin, `clearScope` riparte lazy. Nessun evento resta più
  senza `trace_id`.

## [0.4.0] - 2026-07-02

### Aggiunto
- **Device/OS/app context automatici**: `contexts.device` (model, manufacturer, simulator),
  `contexts.os` (name, version) e `contexts.app` (app_version, build_number, bundle_id) raccolti
  all'init via `device_info_plus` + `package_info_plus` e installati nello scope — ogni evento li
  eredita. Best-effort su ogni piattaforma (web incluso), provider iniettabile nei test
  (`DeviceContextProvider`). Config `collectDeviceContext` (default true).
- **Auto-release**: quando `options.release` non è impostata, la release diventa
  `app_version+build_number` (stile pubspec) derivata dall'app context; le options esplicite vincono.

### Corretto
- Assert di versione SDK stantii nei test (`0.1.0` → `0.3.0`, rotti dal bump di release).

## [0.3.0] - 2026-06-29

### Aggiunto
- **Rilevamento performance issue** (opt-in `detectPerformanceIssues`, default OFF; specchio mobile
  del gem `closeyourit-ruby`). Verdetti `kind=performance_issue` verso `/metrics`, con `trace_id`:
  - `slow_external_http` — chiamata HTTP esterna oltre `slowExternalThresholdMs` (interceptor Dio;
    esclude l'endpoint CloseYourIt, path templatizzato).
  - `repeated_http` — N chiamate identiche (host+path) entro `repeatedHttpWindowMs` (l'N+1 del mobile).
  - `jank` — frame oltre `jankFrameBudgetMs` (default 32) via `addTimingsCallback`, attribuito alla
    route corrente (dal `CloseYourItNavigatorObserver`).
  - `rebuild_storm` — widget ricostruito troppe volte, via la sonda opt-in `CloseYourItRebuildProbe`.
- **`trace_id` sulle metriche** (`MetricEvent`/`slow_method`) — correlazione con log ed errori.

## [0.2.0] - 2026-06-29

### Changed
- **BREAKING (minore)**: `measure()` / `MetricEvent` con `label` vuota ora solleva `ArgumentError`.
  La label è il fingerprint di `slow_method`: vuota collassava tutte le metriche in un unico gruppo.

### Fixed
- **Scrub dei messaggi d'eccezione**: `exception.value` passa dallo scrubber (`Scrubber.scrubMessage`)
  prima dell'invio — il backend non ri-scrubba i messaggi (parità con il gem, niente PII in chiaro).
- **Chunking dei log a `logsMaxBatch` (1000)**: un flush oltre il limite del server veniva rigettato
  in blocco (413) coi log persi; ora è spezzato in invii sequenziali.
- **`contexts.runtime.version`** ora presente (versione SDK) — parità col gem.
- **`LogLevel.fromString`**: alias `err`→error e `unknown`→fatal (parità col gem).

## [0.1.0] - 2026-06-29

Prima release. Specchio Flutter del gem `closeyourit-ruby`.

### Added
- `CloseYourIt.init` con `appRunner` (zona protetta + gestori globali errori).
- Cattura errori: `captureException`/`captureMessage`, dedup, sampling, formato Sentry.
- Scope: `setUser`/`setTag`/`setContext`/`setExtra`/`setTraceId`/`configureScope`/`clearScope`.
- Breadcrumbs con ring buffer e scrubbing PII.
- Metriche: `measure()` → `slow_method` oltre soglia.
- Logs: `log`/`logger` con batching (size/intervallo/lifecycle) e `trace_id`.
- Transport HTTP fire-and-forget (Bearer `cyi_`, redirect, mai solleva) + background worker bounded.
- Integrazioni: `CloseYourItDioInterceptor`, `CloseYourItNavigatorObserver`, flush su lifecycle.
- Scrubber PII e hook `beforeSend`.
