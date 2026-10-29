part of 'confluence_sync_tools.dart';

/// Parallel Confluence execution over [SyncWorkerPool] (gh-348 — Java
/// `ConfluenceParallel` + `ConfluencePageDownloader` perf/robustness
/// ports, dm.ai d61a4abd / 8cbf550d).
///
/// Job kinds served by [_runConfluenceJob] in every pool worker (and on
/// the calling isolate as the inline fallback when the pool is not
/// booted):
/// - [_kJobResolve] — one `contentByUrl` resolution (redirect hops
///   included) for a single URL;
/// - [_kJobHttpGet] — one plain GET (attachment listings);
/// - [_kJobAttachmentGet] — one attachment download with the transient
///   retry schedule ([fetchConfluenceAttachmentWithRetry]).
///
/// Results travel as sendable maps; HTTP responses are wrapped by
/// [_httpJobEnvelope] and rebuilt by [_httpJobResponse].

/// Job kind: resolve one page URL to its content object.
const _kJobResolve = 'resolve';

/// Job kind: one plain GET (attachment listings).
const _kJobHttpGet = 'http-get';

/// Job kind: one attachment download with transient-failure retry.
const _kJobAttachmentGet = 'attachment-get';

/// Java `ConfluenceParallel.DEFAULT_PARALLELISM` (dm.ai d61a4abd).
const _defaultConfluenceParallelism = 4;

/// Java `ConfluenceParallel.MAX_PARALLELISM` (dm.ai d61a4abd).
const _maxConfluenceParallelism = 16;

/// The shared Confluence pool; boots lazily from `CliDispatcher` right
/// before a command that can reach a Confluence sync tool (direct
/// `confluence_*` invocation, or any job run while Confluence is
/// configured) — the same event-loop-alive guarantee as the engine pool:
/// once a QuickJS host callback blocks the main isolate, `Isolate.spawn`
/// can no longer progress.
final SyncWorkerPool _confluenceSyncPool = SyncWorkerPool(
  _confluenceSyncWorkerEntry,
  name: 'confluence-parallel',
  workerCount: confluenceSyncParallelism(),
);

/// Confluence pool worker entry ([Isolate.spawn] target — top-level on
/// purpose: entries cannot capture state, so the runner binds here in the
/// worker isolate).
Future<void> _confluenceSyncWorkerEntry(SyncWorkerBoot boot) =>
    serveSyncWorker(boot, _runConfluenceJob);

/// The shared Confluence parallel worker pool (gh-348).
///
/// Booted by the CLI lazily, just before a command that can reach a
/// Confluence sync tool; when unbooted (tests, embedded use, commands
/// that never touch Confluence) every parallel call falls back to inline
/// sequential execution with identical semantics.
SyncWorkerPool get confluenceSyncWorkerPool => _confluenceSyncPool;

/// Java `ConfluenceParallel.parallelism()` parity (dm.ai d61a4abd):
/// the `CONFLUENCE_PARALLELISM` config value clamped to
/// `[1, _maxConfluenceParallelism]`, defaulting to 4 when unset or
/// unparsable.
int confluenceSyncParallelism([PropertyReader? reader]) {
  final raw = (reader ?? PropertyReader())
      .getValue(PropertyNames.CONFLUENCE_PARALLELISM);
  final parsed = int.tryParse((raw ?? '').trim());
  if (parsed == null) return _defaultConfluenceParallelism;
  if (parsed < 1) return 1;
  if (parsed > _maxConfluenceParallelism) return _maxConfluenceParallelism;
  return parsed;
}

/// Whether Confluence sync tools can run at all: the resolved config
/// carries a base path and credentials (the same guard as `_config()` —
/// unconfigured calls fail before any pool use, so a pool boot would be
/// pure waste). Gates the CLI's lazy pool boot.
bool confluenceSyncConfigured(PropertyReader reader) {
  final basePath = reader.getConfluenceBasePath();
  if (basePath == null || basePath.isEmpty) return false;
  final token = reader.getConfluenceLoginPassToken();
  return token != null && token.isNotEmpty;
}

/// Boots the Confluence parallel pool (gh-348) before a command that can
/// reach a Confluence sync tool — a direct `confluence_*` invocation, or
/// any job run while Confluence is configured (an agent's tool calls
/// execute inside QuickJS host callbacks that block the main isolate's
/// event loop, so the boot cannot happen later).
///
/// Lazy like the engine pool (gh-241): every other command keeps zero
/// pool cost. A boot failure is reported through [onError] and the
/// command proceeds — sync Confluence tools then run through the
/// documented inline sequential fallback ([pool] unbooted) instead of
/// aborting.
Future<void> bootConfluenceSyncPool(
  PropertyReader reader, {
  SyncWorkerPool? pool,
  required void Function(String line) onError,
}) async {
  if (!confluenceSyncConfigured(reader)) return;
  try {
    await (pool ?? confluenceSyncWorkerPool).boot();
  } catch (e) {
    onError('dmtools: Confluence worker pool boot failed '
        '(confluence tools run sequentially): $e');
  }
}

/// The Confluence pool runner ([SyncWorkerRunner]): executes one job by
/// [kind]. Never throws — a failed job reports `null` (Java parity: a
/// failing task yields null instead of aborting the others).
Map<String, dynamic>? _runConfluenceJob(
  String kind,
  Map<String, dynamic> args,
) {
  switch (kind) {
    case _kJobHttpGet:
      return _httpJobEnvelope(SyncHttpClient.get(
        args['url'] as String,
        headers: _argsHeaders(args),
        followRedirects: args['followRedirects'] == true,
      ));
    case _kJobAttachmentGet:
      return _httpJobEnvelope(fetchConfluenceAttachmentWithRetry(
        args['url'] as String,
        _argsHeaders(args),
        baseDelayMs:
            args['baseDelayMs'] as int? ?? confluenceAttachmentRetryBaseDelayMs,
      ));
    case _kJobResolve:
      return _resolveContentJob(args);
    default:
      return null;
  }
}

/// The `resolve` job body: rebuilds the resolved config worker-side and
/// runs the Java `contentByUrl` resolution for one URL; `null` on any
/// failure (the caller skips it like Java's warn + continue).
Map<String, dynamic>? _resolveContentJob(Map<String, dynamic> args) {
  final config = (
    rootUrl: args['rootUrl'] as String,
    baseUrl: args['baseUrl'] as String,
    headers: _argsHeaders(args),
    apiVersion: '${args['apiVersion']}',
    attachmentRetryBaseDelayMs:
        args['baseDelayMs'] as int? ?? confluenceAttachmentRetryBaseDelayMs,
  );
  try {
    return _contentFromUrl(config, args['url'] as String);
  } catch (_) {
    return null;
  }
}

/// One `resolve` job per URL of [urls]; results keep the input order.
List<SyncParallelJob> _resolveJobs(_Conf config, List<String> urls) => [
      for (var i = 0; i < urls.length; i++)
        SyncParallelJob(
          index: i,
          kind: _kJobResolve,
          args: {..._jobArgsOf(config), 'url': urls[i]},
        ),
    ];

/// The sendable config fields shared by every Confluence job.
Map<String, dynamic> _jobArgsOf(_Conf config) => <String, dynamic>{
      'rootUrl': config.rootUrl,
      'baseUrl': config.baseUrl,
      'headers': config.headers,
      'apiVersion': config.apiVersion,
      'baseDelayMs': config.attachmentRetryBaseDelayMs,
    };

/// String map coercion of a job's `headers` argument.
Map<String, String> _argsHeaders(Map<String, dynamic> args) =>
    (args['headers'] as Map).map((k, v) => MapEntry('$k', '$v'));

/// Wraps a sync HTTP response into a sendable job-result map.
Map<String, dynamic> _httpJobEnvelope(SyncHttpResponse resp) =>
    <String, dynamic>{
      'status': resp.statusCode,
      'headers': resp.headers,
      'body': base64Encode(resp.bodyBytes),
    };

/// Rebuilds the response wrapped by [_httpJobEnvelope]; `null` when the
/// job failed.
SyncHttpResponse? _httpJobResponse(Map<String, dynamic>? envelope) {
  if (envelope == null) return null;
  final bytes = base64Decode(envelope['body'] as String);
  return SyncHttpResponse(
    envelope['status'] as int,
    utf8.decode(bytes, allowMalformed: true),
    (envelope['headers'] as Map).map((k, v) => MapEntry('$k', '$v')),
    bytes,
  );
}

/// Runs [jobs] on the Confluence pool, or inline — in input order, one
/// at a time on the calling isolate — when the pool is not booted.
List<Map<String, dynamic>?> _runConfluenceParallel(
  List<SyncParallelJob> jobs,
) {
  final pool = confluenceSyncWorkerPool;
  if (pool.ready) return pool.run(jobs);
  return <Map<String, dynamic>?>[for (final job in jobs) _runJobInline(job)];
}

/// Executes one job on the calling isolate with pool-failure semantics
/// (any throw degrades to `null`).
Map<String, dynamic>? _runJobInline(SyncParallelJob job) {
  try {
    return _runConfluenceJob(job.kind, job.args);
  } catch (_) {
    return null;
  }
}
