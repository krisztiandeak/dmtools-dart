/// Shared engine wiring for the main JS engine and `runAsync` workers.
///
/// Extracted from [JsJobRunner] (its `_wireRuntime` pipeline) so that async
/// worker isolates build their engines through the exact same code path —
/// one wiring implementation, one behavior. A worker engine is "just another
/// engine": same context injection, same require loader, same generated tool
/// wrappers, same host functions.
///
/// Ordering (Java `JobJavaScriptBridge.initializeJavaScriptContext` parity):
/// context injection → extra globals → require loader → tool wrappers →
/// host functions last, so the direct `file_read` global wins over the
/// generated wrapper (testRunner.js relies on the raw-content contract).
library;

import 'dart:convert';
import 'dart:io';

import '../mcp/default_tool_registry.dart';
import '../mcp/tool_registry.dart';
import 'package:quickjs_runtime/quickjs_runtime.dart';
import 'require_loader.dart';
import 'sync_http_client.dart';
import 'tool_bridge.dart';
import 'tool_wrapper_generator.dart';

/// Everything needed to wire one QuickJS engine for a job context.
class EngineSpec {
  /// Creates an engine specification.
  const EngineSpec({
    this.context = const EngineContext(),
    this.registry,
    this.integrationFilter,
    this.workingDirectory,
    this.scriptDirectory,
    this.consolePrefix,
    this.httpFetch,
  });

  /// The `params` composition for the script (Java `.with()` bindings,
  /// `params.jobParams` / `params.ticket`).
  final EngineContext context;

  /// Tool registry; defaults to the full catalog when null.
  final ToolRegistry? registry;

  /// Restricts generated wrappers to the named integrations.
  final Set<String>? integrationFilter;

  /// Base for relative paths in tool calls (defaults to current directory).
  final String? workingDirectory;

  /// Script directory applied via `__setScriptDirectory` after wiring
  /// (relative `require` base for worker jobs).
  final String? scriptDirectory;

  /// Prefix prepended to every `console.*` line (worker log attribution);
  /// null keeps the default unprefixed output.
  final String? consolePrefix;

  /// Alternate `fetch` transport for the node/js compat layer
  /// (`String? Function(String requestJson)` — JSON in, JSON out).
  /// Defaults to the pooled [SyncHttpClient] transport. Only applied to
  /// engines wired directly with this spec: worker isolates receive the
  /// default transport because closures cannot cross a `SendPort`
  /// (dispatch contexts are JSON-marshaled).
  final String? Function(String requestJson)? httpFetch;
}

/// The `params` composition inputs of an [EngineSpec].
class EngineContext {
  /// Creates a context from the job-composition fields.
  const EngineContext({
    this.jobParams = const {},
    this.ticket,
    this.contextParams,
    this.extraGlobals,
    this.directParams,
  });

  /// Pre-composed `params` object (worker jobs receive the exact map the
  /// main engine composed — JSON round-tripped); the composition fields
  /// are ignored.
  const EngineContext.direct(Map<String, dynamic> params)
      : directParams = params,
        jobParams = const {},
        ticket = null,
        contextParams = null,
        extraGlobals = null;

  /// Injected as `params.jobParams` (ignored in [EngineContext.direct]).
  final Map<String, dynamic> jobParams;

  /// Injected as `params.ticket` when non-null.
  final Map<String, dynamic>? ticket;

  /// Extra `params.*` entries (Java `.with()` bindings).
  final Map<String, dynamic>? contextParams;

  /// Extra top-level JS globals set after `params`.
  final Map<String, dynamic>? extraGlobals;

  /// Pre-composed `params` object; non-null in [EngineContext.direct].
  final Map<String, dynamic>? directParams;
}

/// Builds the flattened `params` object the script sees.
///
/// Java `JavaScriptExecutor.execute()` parity: ONE map — `jobParams`,
/// `ticket`, every `.with(key, value)` binding and extra global are members
/// of the same object (extras ALSO stay top-level; see [JsJobRunner]).
Map<String, dynamic> buildParamsMap({
  required Map<String, dynamic> jobParams,
  Map<String, dynamic>? ticket,
  Map<String, dynamic>? contextParams,
  Map<String, dynamic>? extraGlobals,
}) {
  return {
    'jobParams': jobParams,
    if (ticket != null) 'ticket': ticket,
    ...?contextParams,
    ...?extraGlobals,
  };
}

/// Wires job context, require loader, tool wrappers, and host functions on
/// [rt] per [spec].
NodeCompatHandle? wireEngine(QuickjsRuntime rt, EngineSpec spec) {
  final ctx = spec.context;
  final params = ctx.directParams ??
      buildParamsMap(
        jobParams: ctx.jobParams,
        ticket: ctx.ticket,
        contextParams: ctx.contextParams,
        extraGlobals: ctx.extraGlobals,
      );
  rt.setGlobal('params', params);
  _injectExtraGlobals(rt, ctx.extraGlobals);
  final registry = spec.registry ?? createDefaultToolRegistry();
  // Order matters twice over (gh-369):
  // 1. host functions are registered before [installRequireLoader] so the
  //    loader can capture `__loaderReadHost` and delete the global;
  // 2. the JS host wrappers are installed AFTER the generated tool
  //    wrappers so the direct `file_read` host keeps precedence.
  final bridge = ToolBridge(
    registry: registry,
    workingDirectory: spec.workingDirectory,
    consolePrefix: spec.consolePrefix,
  );
  bridge.registerHostFunctions(rt);
  installRequireLoader(rt);
  rt.eval(
    buildWrapperSource(registry, spec.integrationFilter),
    filename: '<tool_wrappers>',
  );
  if (spec.scriptDirectory != null) {
    // `__setScriptDirectory` expects a file path and derives its directory
    // (JS `scriptDirOf`); workers receive the directory already, so anchor
    // it with a virtual job file name.
    setScriptDirectory(rt, '${spec.scriptDirectory}/__jsr_job__.js');
  }
  bridge.installHostWrappers(rt);
  return _installNodeCompatIfEnabled(rt, spec);
}

/// Installs the opt-in node/js compat layer when the job's `jobParams`
/// carry `nodeCompat: true` — Java `JobJavaScriptBridge` parity
/// (`params.jobParams.nodeCompat === true`, default-off). Runs LAST in
/// [wireEngine] so the compat `require` captures the loader's `require`
/// as its fallback and the compat `console` replaces the product console.
///
/// Because every engine — main and `runAsync` worker alike — is wired
/// through [wireEngine], dispatched functions see the same compat surface
/// as the main script (Java installs it in the worker bridges too).
///
/// Hooks: real UTF-8 codecs from `dart:convert` (the package defaults are
/// latin-1 approximations, not script-faithful) and a console sink
/// mirroring the product console split — `log/info/debug/trace` to
/// stdout, `warn/error` to stderr, worker prefix preserved.
NodeCompatHandle? _installNodeCompatIfEnabled(
  QuickjsRuntime rt,
  EngineSpec spec,
) {
  final ctx = spec.context;
  final jobParams = (ctx.directParams?['jobParams'] as Map?) ?? ctx.jobParams;
  if (jobParams['nodeCompat'] != true) return null;
  final prefix = spec.consolePrefix;
  return installNodeCompat(
    rt,
    NodeCompatConfig(
      utf8Encode: utf8.encode,
      utf8Decode: utf8.decode,
      consoleSink: (level, message) {
        final sink = (level == 'warn' || level == 'error') ? stderr : stdout;
        sink.writeln(prefix == null ? message : '$prefix$message');
      },
      httpFetch: spec.httpFetch ?? _syncFetch,
      // dmtools is a headless CLI: "setTimeout as sleep" must behave like
      // Node, so timers drain in block mode (bounded by the jsr defaults:
      // maxTimerCallbacks per pass + maxTimerDrainWallClock). The returned
      // handle is drained by the job runner / async pool after each script
      // or dispatched job completes.
      timerDrain: TimerDrainMode.block,
      scriptPath: spec.scriptDirectory == null
          ? null
          : '${spec.scriptDirectory}/__jsr_job__.js',
    ),
  );
}

/// The `fetch` transport: routes through the same pooled sync HTTP client
/// the tools use ([SyncHttpClient]); status `0` (transport failure) maps
/// to Node's `fetch failed`.
String? _syncFetch(String requestJson) {
  final request = jsonDecode(requestJson) as Map<String, dynamic>;
  final method = (request['method'] as String? ?? 'GET').toUpperCase();
  final url = request['url'] as String? ?? '';
  final headers = (request['headers'] as Map<String, dynamic>? ?? const {})
      .map((k, v) => MapEntry(k, '$v'));
  final body = request['body'] as String?;
  try {
    final resp = SyncHttpClient.dispatch(
      method,
      url,
      headers: headers,
      body: body,
    );
    return jsonEncode({
      'status': resp.statusCode,
      'headers': resp.headers,
      'body': resp.body,
    });
  } catch (e) {
    return jsonEncode({'error': '$e'});
  }
}

/// Sets the `require` base directory from the top-level script path.
///
/// Java `setCurrentScriptDirectory` parity: the last `/`-separated parent,
/// or `''` when there is none — applied verbatim even when the "path" is
/// inline code.
void setScriptDirectory(QuickjsRuntime rt, String scriptPath) {
  rt.eval(
    '__setScriptDirectory(${jsonEncode(scriptPath)})',
    filename: '<set_script_dir>',
  );
}

/// The `require` base directory of [scriptPath] (JS `scriptDirOf` parity).
String jsDirectoryOf(String scriptPath) {
  if (!scriptPath.contains('/')) return '';
  return scriptPath.substring(0, scriptPath.lastIndexOf('/'));
}

final Expando<Map<String, String>> _wrapperSourceCache = Expando();

/// Generates tool wrapper JS for [registry], optionally narrowed by
/// [filter].
String buildWrapperSource(ToolRegistry registry, Set<String>? filter) {
  final byFilter = _wrapperSourceCache[registry] ??= <String, String>{};
  final filterKey = filter == null
      ? '${registry.allTools.length}:*'
      : '${registry.allTools.length}:${(filter.toList()..sort()).join(',')}';
  return byFilter.putIfAbsent(filterKey, () {
    final source = filter == null
        ? registry
        : (ToolRegistry()..registerAll(registry.toolsForIntegrations(filter)));
    return const ToolWrapperGenerator().generate(source);
  });
}

/// Sets each [extraGlobals] entry as a top-level JS global on [rt].
void _injectExtraGlobals(
  QuickjsRuntime rt,
  Map<String, dynamic>? extraGlobals,
) {
  if (extraGlobals == null) return;
  for (final entry in extraGlobals.entries) {
    rt.setGlobal(entry.key, entry.value);
  }
}
