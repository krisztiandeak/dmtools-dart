/// Parallel execution and resilient retry helpers for `TicketInputContextBuilder`
/// and `TicketSmartSources`.
///
/// Architecture:
/// - **Per-client lane**: Each external integration client (Confluence, Figma,
///   ticket attachments, linked tickets) has its own bounded [SyncWorkerPool]
///   so one slow or rate-limited integration never blocks another.
/// - **Intra-client worker concurrency**: Within each client lane, requests
///   fan out across `N` workers (default: 3, configurable via
///   [InputContextConfig.clientConcurrency], per-client `*Concurrency` keys,
///   or `INPUT_<CLIENT>_CONCURRENCY` / `INPUT_CLIENT_CONCURRENCY` env vars).
/// - **Rate-limit & transient fault resilience**: Attachment and smart-source
///   downloads retry HTTP 429 / 408 / 5xx and transport failures (`status 0`)
///   with exponential backoff + jitter and honor `Retry-After` /
///   `X-RateLimit-Reset` headers via [SyncHttpClient] and
///   [downloadAttachmentBytesResilient].
library;

import 'dart:io';
import 'dart:math';

import '../config/property_reader.dart';
import '../config/property_reader_getters.dart';
import '../js/sync_http_client.dart';
import '../js/sync_parallel.dart';
import '../js/sync_tools/confluence_sync_tools.dart';
import '../js/sync_tools/figma_sync_tools.dart';
import 'input_context_config.dart';
import 'ticket_input_context_builder.dart';
import 'ticket_smart_sources.dart';

/// Job kind: download one attachment URL with redirect + auth + retry handling.
const String kInputJobAttachmentDownload = 'attachment-download';

/// Job kind: download all Figma metadata + preview image for one Figma URL.
const String kInputJobFigmaRef = 'figma-ref';

/// Job kind: fetch a linked ticket by key (Jira / GitHub / ADO).
const String kInputJobFetchTicket = 'fetch-ticket';

/// Job kind: run the Confluence downloader lane.
const String kInputJobConfluenceLane = 'confluence-lane';

/// Registry of per-client worker pools used during input context building.
class InputContextParallelPools {
  InputContextParallelPools._();

  static SyncWorkerPool? _orchestratorPool;
  static final Map<int, SyncWorkerPool> _attachmentsPools =
      <int, SyncWorkerPool>{};
  static final Map<int, SyncWorkerPool> _figmaPools = <int, SyncWorkerPool>{};
  static final Map<int, SyncWorkerPool> _ticketsPools = <int, SyncWorkerPool>{};

  /// Pool that runs separate integration client lanes concurrently.
  static SyncWorkerPool get orchestratorPool =>
      _orchestratorPool ??= SyncWorkerPool(
        _inputContextWorkerEntry,
        name: 'input-client-lane',
        workerCount: 4,
      );

  /// Pool for ticket attachment downloads (default 3 workers).
  static SyncWorkerPool attachmentsPool([int workers = 3]) {
    final w = clampInputClientConcurrency(workers);
    return _attachmentsPools.putIfAbsent(
      w,
      () => SyncWorkerPool(
        _inputContextWorkerEntry,
        name: 'input-attachments-$w',
        workerCount: w,
      ),
    );
  }

  /// Pool for Figma design metadata & image downloads (default 3 workers).
  static SyncWorkerPool figmaPool([int workers = 3]) {
    final w = clampInputClientConcurrency(workers);
    return _figmaPools.putIfAbsent(
      w,
      () => SyncWorkerPool(
        _inputContextWorkerEntry,
        name: 'input-figma-$w',
        workerCount: w,
      ),
    );
  }

  /// Pool for linked ticket hydration across Jira/GitHub/ADO (default 3 workers).
  static SyncWorkerPool ticketsPool([int workers = 3]) {
    final w = clampInputClientConcurrency(workers);
    return _ticketsPools.putIfAbsent(
      w,
      () => SyncWorkerPool(
        _inputContextWorkerEntry,
        name: 'input-tickets-$w',
        workerCount: w,
      ),
    );
  }

  /// Boots the per-client worker pools while the main isolate's event loop is
  /// alive (before `TicketInputContextBuilder.build` runs).
  ///
  /// Any boot failure is logged to [onError] and ignored so execution
  /// gracefully degrades to the inline sequential fallback.
  static Future<void> bootAll(
    PropertyReader reader, {
    InputContextConfig? config,
    void Function(String message)? onError,
  }) async {
    final cfg = config ?? InputContextConfig();
    final parallelLanes = cfg.isParallelClientsEnabled(reader);
    final caps = SourceCapabilities(reader);
    final futures = <Future<void>>[
      if (parallelLanes) _bootOne(orchestratorPool, onError),
      if (cfg.concurrencyFor('attachments', reader) > 1)
        _bootOne(
          attachmentsPool(cfg.concurrencyFor('attachments', reader)),
          onError,
        ),
      if (caps.isFigmaConfigured && cfg.concurrencyFor('figma', reader) > 1)
        _bootOne(figmaPool(cfg.concurrencyFor('figma', reader)), onError),
      if ((caps.isJiraConfigured ||
              caps.isGithubConfigured ||
              caps.isAdoConfigured) &&
          cfg.concurrencyFor('tickets', reader) > 1)
        _bootOne(ticketsPool(cfg.concurrencyFor('tickets', reader)), onError),
      if (caps.isConfluenceConfigured &&
          cfg.concurrencyFor('confluence', reader) > 1)
        bootConfluenceSyncPool(
          reader,
          onError: onError ?? stderr.writeln,
        ),
    ];
    await Future.wait(futures);
  }

  static Future<void> _bootOne(
    SyncWorkerPool pool,
    void Function(String message)? onError,
  ) async {
    if (pool.ready) return;
    try {
      await pool.boot();
    } catch (e) {
      (onError ?? stderr.writeln)(
        'dmtools: ${pool.name} pool boot failed (falling back to inline): $e',
      );
    }
  }

  /// Disposes all pools (used in tests).
  static void disposeAll() {
    _orchestratorPool?.dispose();
    _orchestratorPool = null;
    for (final p in _attachmentsPools.values) {
      p.dispose();
    }
    _attachmentsPools.clear();
    for (final p in _figmaPools.values) {
      p.dispose();
    }
    _figmaPools.clear();
    for (final p in _ticketsPools.values) {
      p.dispose();
    }
    _ticketsPools.clear();
    confluenceSyncWorkerPool.dispose();
  }
}

/// Top-level worker entry point for `Isolate.spawn`.
Future<void> _inputContextWorkerEntry(SyncWorkerBoot boot) =>
    serveSyncWorker(boot, runInputContextWorkerJob);

/// Executes one parallel job in a worker isolate or inline on the calling
/// isolate when the pool is unbooted or `concurrency == 1`.
Map<String, dynamic>? runInputContextWorkerJob(
  String kind,
  Map<String, dynamic> args,
) {
  final overrides = _stringMapOf(args['overrides']);
  final prevIsolation = PropertyReader.testIsolation;
  final prev = PropertyReader.getOverrides();
  try {
    if (args['testIsolation'] == true) PropertyReader.testIsolation = true;
    if (overrides.isNotEmpty) PropertyReader.setOverrides(overrides);
    final reader = PropertyReader();
    return _dispatchWorkerKind(kind, reader, args);
  } finally {
    PropertyReader.testIsolation = prevIsolation;
    if (overrides.isNotEmpty) {
      if (prev.isEmpty) {
        PropertyReader.clearOverrides();
      } else {
        PropertyReader.setOverrides(prev);
      }
    }
  }
}

Map<String, dynamic>? _dispatchWorkerKind(
  String kind,
  PropertyReader reader,
  Map<String, dynamic> args,
) {
  switch (kind) {
    case kInputJobAttachmentDownload:
      return _executeAttachmentDownloadJob(reader, args);
    case kInputJobFigmaRef:
      return _executeFigmaRefJob(reader, args);
    case kInputJobFetchTicket:
      return _executeFetchTicketJob(reader, args);
    case kInputJobConfluenceLane:
      return _executeConfluenceLaneJob(reader, args);
    default:
      return null;
  }
}

/// Runs [jobs] with a concurrency cap of [maxConcurrency] using [pool] when
/// booted and `maxConcurrency > 1`, or inline sequentially otherwise.
///
/// When `jobs.length > maxConcurrency`, jobs are executed in waves of size
/// [maxConcurrency] so the target integration is never hit by more than
/// [maxConcurrency] simultaneous requests (rate-limit protection).
List<Map<String, dynamic>?> runBoundedClientJobs(
  List<SyncParallelJob> jobs, {
  required SyncWorkerPool pool,
  required int maxConcurrency,
}) {
  if (jobs.isEmpty) return const <Map<String, dynamic>?>[];
  final limit = clampInputClientConcurrency(maxConcurrency);
  if (limit <= 1 || !pool.ready || jobs.length == 1) {
    return <Map<String, dynamic>?>[
      for (final job in jobs) _runInlineSafe(job),
    ];
  }
  final results = List<Map<String, dynamic>?>.filled(jobs.length, null);
  for (var offset = 0; offset < jobs.length; offset += limit) {
    final end = min(offset + limit, jobs.length);
    final batch = <SyncParallelJob>[
      for (var i = offset; i < end; i++)
        SyncParallelJob(
          index: i - offset,
          kind: jobs[i].kind,
          args: jobs[i].args,
        ),
    ];
    final batchResults = pool.run(batch);
    for (var i = 0; i < batchResults.length; i++) {
      results[offset + i] = batchResults[i];
    }
  }
  return results;
}

Map<String, dynamic>? _runInlineSafe(SyncParallelJob job) {
  try {
    return runInputContextWorkerJob(job.kind, job.args);
  } catch (e) {
    stderr.writeln('dmtools: input context job (${job.kind}) failed: $e');
    return null;
  }
}

/// Captures the active [PropertyReader] overrides + test environment so worker
/// isolates resolve identical credentials and base URLs.
Map<String, String> capturePropertyOverrides() => <String, String>{
      if (PropertyReader.testIsolation) ...PropertyReader.testEnvironment,
      ...PropertyReader.getOverrides(),
    };

Map<String, String> _stringMapOf(dynamic raw) {
  if (raw is! Map) return const <String, String>{};
  return raw.map((k, v) => MapEntry('$k', '$v'));
}

Map<String, dynamic>? _executeAttachmentDownloadJob(
  PropertyReader reader,
  Map<String, dynamic> args,
) {
  final url = args['url']?.toString() ?? '';
  final outPath = args['outPath']?.toString() ?? '';
  if (url.isEmpty || outPath.isEmpty) return const {'ok': false};
  final bytes = downloadAttachmentBytesResilient(url, reader);
  if (bytes == null) return const {'ok': false};
  return writeAttachmentBytesAtomically(outPath, bytes)
      ? <String, dynamic>{'ok': true, 'bytes': bytes.length}
      : const {'ok': false};
}

/// Writes [bytes] to [outPath] atomically via a `.part` temporary sibling file
/// and rename so a failed write never leaves a corrupt partial file.
bool writeAttachmentBytesAtomically(String outPath, List<int> bytes) {
  final file = File(outPath);
  final partFile = File('$outPath.part');
  try {
    file.parent.createSync(recursive: true);
    partFile.writeAsBytesSync(bytes, flush: true);
    partFile.renameSync(outPath);
    return true;
  } catch (_) {
    try {
      if (partFile.existsSync()) partFile.deleteSync();
    } catch (_) {}
    return false;
  }
}

/// Downloads [url] following up to 5 HTTP 3xx redirects while re-resolving
/// origin-scoped auth headers per hop (gh-461) and retrying transient or
/// rate-limit failures (`429`, `408`, `5xx`, `status 0`) with exponential
/// backoff + jitter.
List<int>? downloadAttachmentBytesResilient(
  String url,
  PropertyReader reader, {
  SyncHttpResponse Function(String url, Map<String, String>? headers)? httpGet,
  void Function(int delayMs)? sleepFn,
  int? maxAttempts,
  int? baseDelayMs,
}) {
  final get = httpGet ??
      (u, h) => SyncHttpClient.get(u, headers: h, followRedirects: false);
  final pause = sleepFn ?? (ms) => sleep(Duration(milliseconds: ms));
  final rnd = Random();
  final attempts = maxAttempts ?? reader.getInputDownloadRetryAttempts();
  final baseMs = baseDelayMs ?? reader.getInputDownloadRetryBaseDelayMs();
  for (var attempt = 1; attempt <= attempts; attempt++) {
    final result = _downloadSingleRedirectChain(url, reader, get);
    if (result.bytes != null) return result.bytes;
    if (!result.transient || attempt >= attempts) return null;
    final delay = _retryDelayMs(
      attempt: attempt,
      baseDelayMs: baseMs,
      headers: result.headers,
      rnd: rnd,
    );
    pause(delay);
  }
  return null;
}

typedef _RedirectResult = ({
  List<int>? bytes,
  bool transient,
  Map<String, String> headers,
});

_RedirectResult _downloadSingleRedirectChain(
  String url,
  PropertyReader reader,
  SyncHttpResponse Function(String url, Map<String, String>? headers) get,
) {
  var current = url;
  for (var hop = 0; hop <= 5; hop++) {
    final headers = TicketInputContextBuilder.resolveAuthHeadersForUrl(
      current,
      reader,
    );
    final resp = get(current, headers);
    if (resp.isOk) {
      return (bytes: resp.bodyBytes, transient: false, headers: resp.headers);
    }
    final next = _nextRedirectTarget(resp, current, hop);
    if (next == null) {
      return _failedRedirectResult(resp, current);
    }
    current = next;
  }
  return (bytes: null, transient: false, headers: const {});
}

String? _nextRedirectTarget(SyncHttpResponse resp, String current, int hop) {
  if (!resp.isRedirect || hop >= 5) return null;
  final location = _locationHeaderOf(resp.headers);
  return location == null
      ? null
      : Uri.parse(current).resolve(location).toString();
}

_RedirectResult _failedRedirectResult(SyncHttpResponse resp, String current) {
  final isTransient = _isTransientStatus(resp.statusCode);
  if (!isTransient) {
    stderr.writeln(
      'Attachment download failed (HTTP ${resp.statusCode}) for $current',
    );
  }
  return (bytes: null, transient: isTransient, headers: resp.headers);
}

bool _isTransientStatus(int status) =>
    status == 0 || status == 408 || status == 429 || status >= 500;

int _retryDelayMs({
  required int attempt,
  required int baseDelayMs,
  required Map<String, String> headers,
  required Random rnd,
}) {
  final retryAfter = _retryAfterSeconds(headers);
  if (retryAfter != null && retryAfter > 0) {
    return min(retryAfter * 1000, 60000);
  }
  final exp = baseDelayMs * (1 << (attempt - 1));
  final jitter = baseDelayMs < 2 ? 0 : rnd.nextInt(baseDelayMs ~/ 2);
  return min(exp + jitter, 30000);
}

int? _retryAfterSeconds(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'retry-after') {
      return int.tryParse(entry.value.trim());
    }
  }
  return null;
}

String? _locationHeaderOf(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'location' && entry.value.isNotEmpty) {
      return entry.value;
    }
  }
  return null;
}

Map<String, dynamic>? _executeFigmaRefJob(
  PropertyReader reader,
  Map<String, dynamic> args,
) {
  final outDirPath = args['figmaDir']?.toString() ?? '';
  final url = args['url']?.toString() ?? '';
  final index = (args['index'] as num?)?.toInt() ?? 1;
  final includeComments = args['includeComments'] == true;
  final includeAttachments = args['includeAttachments'] == true;
  if (outDirPath.isEmpty || url.isEmpty) return const {'ok': false};
  TicketSmartSources(reader, figmaTools: FigmaSyncTools(reader))
      .downloadSingleFigmaUrl(
    Directory(outDirPath),
    url,
    index,
    includeComments: includeComments,
    includeAttachments: includeAttachments,
  );
  return const {'ok': true};
}

List<String> _nonEmptyStringList(dynamic raw) =>
    (raw as List?)
        ?.map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList(growable: false) ??
    const <String>[];

Map<String, dynamic>? _executeFetchTicketJob(
  PropertyReader reader,
  Map<String, dynamic> args,
) {
  final key = args['key']?.toString() ?? '';
  if (key.isEmpty) return null;
  final ticket = TicketSmartSources(reader).fetchTicketByKey(key);
  if (ticket == null) return null;
  return <String, dynamic>{'key': key, 'ticket': ticket};
}

Map<String, dynamic>? _executeConfluenceLaneJob(
  PropertyReader reader,
  Map<String, dynamic> args,
) {
  final urls = _nonEmptyStringList(args['urls']);
  final outDir = args['outDir']?.toString() ?? '';
  if (urls.isEmpty || outDir.isEmpty) return const {'ok': false};
  ConfluenceSyncTools(reader).dispatch('confluence_download_pages', {
    'urlStrings': urls,
    'outputPath': outDir,
    'depth': (args['depth'] as num?)?.toInt() ?? 1,
    'downloadAttachments': args['downloadAttachments'] == true,
    'includeComments': args['includeComments'] == true,
  });
  return const {'ok': true};
}
