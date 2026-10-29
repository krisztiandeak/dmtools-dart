/// Executes a CliAgent job — Dart port of Java `CliAgent`.
///
/// Lifecycle (exact order, mirrors Java `CliAgent.runJobImpl`):
/// ```text
/// setup → preJSAction → preCliJSAction → cliCommands → postJSAction →
/// cache → reset (always runs, even on failure)
/// ```
///
/// Script hooks (`setup`/`cache`/`reset`) run as shell commands unless the
/// path ends with `.js` — then they execute via [JsJobRunner]. JS actions
/// (`preJSAction`/`preCliJSAction`/`postJSAction`) always run via
/// [JsJobRunner]. During the `cliCommands` phase, three further JS actions may
/// fire when configured: `timerJSAction` (periodic, plus a final tick),
/// `cliExecutionErrorJSAction` (on a non-zero exit), and `cliOutputLineJSAction`
/// (per output line; returning `true` stops the batch). Errors in hooks and
/// actions are caught and logged (the lifecycle continues); only CLI command
/// failures can fail the run.
///
/// Strict mode (`requireCliOutputFile=true`) with no CLI output file skips
/// `postJSAction` entirely (Java `skipFieldUpdate` parity, epam/dm.ai#622) —
/// the error summary returned as the response reports the failure instead.
///
/// Manual skip flags (`skipPreJSAction` / `skipPreCliJSAction` /
/// `skipPostJSAction`, Java epam/dm.ai#266 parity) each prevent their hook
/// with a skip log line; the flags compose with the strict-mode guard.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/env_file_parser.dart';
import '../config/property_reader.dart';
import '../config/property_reader_getters.dart';
import '../js/job_runner.dart';
import '../pack/pack_provenance.dart';
import 'cli_agent_params.dart';
import 'cli_command_builder.dart';
import 'cli_execution_helper.dart';
import 'ticket_input_context_builder.dart';
import 'ticket_smart_sources.dart';

/// Executes a CliAgent job — lightweight CLI-agent orchestrator.
///
/// Takes the CLI-execution parts of `Teammate` and removes the
/// tracker-ticket plumbing: runs cursor-agent / claude / copilot-style CLI
/// tools with aggregated prompts and optional setup/cache/reset hooks,
/// without needing an `inputJql` or a ticket system.
class CliAgent {
  /// Creates a CliAgent with the given [params] and optional overrides.
  CliAgent({
    required this.params,
    this.workingDirectory,
    this.ticketData,
    PropertyReader? propertyReader,
    JsJobRunner? jsRunner,
    this.failOnJsActionErrors = false,
  })  : propertyReader = propertyReader ?? PropertyReader(),
        jsRunner = jsRunner ?? const JsJobRunner();

  /// Parameters from the job config.
  final CliAgentParams params;

  /// Working-directory override; when null, `params.workingDirectory` or
  /// the CWD is used.
  final String? workingDirectory;

  /// Raw tracker ticket JSON used to populate the input context.
  ///
  /// When null (no tracker configured), the input context folder is created
  /// empty — the ticket-agnostic behavior.
  final Map<String, dynamic>? ticketData;

  /// Property reader for environment resolution.
  final PropertyReader propertyReader;

  /// JS runner for `.js` actions and hooks.
  final JsJobRunner jsRunner;

  /// Loud JS-action failure propagation (Java `Teammate` parity, #580/#585).
  final bool failOnJsActionErrors;

  /// Set when `preCliJSAction` failed in loud mode (skips CLI + postJSAction).
  bool _preCliJsActionSkipped = false;

  /// Set when `preCliJSAction` threw an uncaught exception in loud mode.
  bool _preCliSetupThrew = false;

  /// Result of the `cliCommands` phase — used by the reset hook.
  CliExecutionResult? _cliResult;

  /// Input context path — cleaned up in the finally block.
  String? _inputContextPath;

  /// Ticket data seen by JS actions (`params.ticket`), resolved once at start.
  Map<String, dynamic>? _resolvedTicketData;

  /// Runs the full lifecycle. Returns a result map.
  ///
  /// - Success: `{'success': true, 'contextId': …, 'response': …}`
  /// - Failure: `{'success': false, 'error': …}`
  ///
  /// The reset hook and folder cleanup always run (in a `finally` block),
  /// mirroring the Java `runJobImpl` finally semantics.
  Future<Map<String, dynamic>> run() async {
    if (params.cliCommands.isEmpty) {
      return {'success': true, 'message': 'No cliCommands provided'};
    }
    // Zone-scoped overrides: two CliAgent jobs running concurrently in one
    // isolate each keep their own `TrackerParams.envVariables` across
    // awaits (Java gets this from ThreadLocal). Merge on top of any active
    // overrides so parent/test overrides remain visible.
    return PropertyReader.runWithOverrides(
      {...PropertyReader.getOverrides(), ...?params.envVariables},
      _runGuarded,
      extraEnv: parseEnvFile('${_resolveWorkingDirectory()}/dmtools.env'),
      basePath: _resolveWorkingDirectory(),
    );
  }

  /// Runs the lifecycle, converting failures into error results.
  Future<Map<String, dynamic>> _runGuarded() async {
    try {
      return await _runLifecycle(_resolveWorkingDirectory());
    } on _JsActionUncaughtException catch (e) {
      // Java Teammate #585 parity: a postJSAction uncaught exception must
      // fail the job (and the CI step) with the full JS error text —
      // never degrade into a swallowed warning.
      return {
        'success': false,
        'error': e.toString(),
        'postJsActionUncaught': true,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Executes the main lifecycle phases inside [workDir].
  Future<Map<String, dynamic>> _runLifecycle(String workDir) async {
    String? response;
    try {
      _resolvedTicketData = _resolveTicketData(workDir);
      _clearStaleOutputs(workDir);
      await _executeScriptHook('setup', params.setup, workDir, null);
      final pre = _executeJsAction(
          'preJSAction', params.preJSAction, null, null, workDir,
          skip: params.skipPreJSAction);
      if (pre?.trim() == 'false') {
        return {
          'success': true,
          'contextId': params.contextId,
          'response': 'Skipped by pre-action'
        };
      }
      _inputContextPath = await _createInputContext(workDir);
      _executeJsAction('preCliJSAction', params.preCliJSAction, null,
          _inputContextPath, workDir,
          skip: params.skipPreCliJSAction);
      response = await _runResponsePhase(workDir);
      await _executeScriptHook('cache', params.cache, workDir, response);
      return {
        'success': true,
        'contextId': params.contextId,
        'response': response,
        if (_preCliSetupThrew) 'unexpectedSetupFailure': true,
      };
    } finally {
      await _executeScriptHook('reset', params.reset, workDir,
          _cliResult != null ? _extractResponse(_cliResult!) : null);
      _performCleanup(workDir);
    }
  }

  // ------------------------------------------------------------------
  // Script hooks (setup / cache / reset)
  // ------------------------------------------------------------------

  /// Executes a script hook: `.js` path via [JsJobRunner], else shell.
  ///
  /// Errors are caught and logged — the lifecycle continues (mirrors Java
  /// `executeScriptHook`).
  Future<void> _executeScriptHook(
    String name,
    String? script,
    String workDir,
    String? response,
  ) async {
    if (script == null || script.trim().isEmpty) return;
    try {
      if (script.endsWith('.js')) {
        jsRunner.runScript(
          scriptPath: script,
          jobParams: _buildJobParams(response, null),
          workingDirectory: workDir,
          config: JsRunConfig(
            extraGlobals: {'workingDirectory': workDir},
          ),
        );
      } else {
        await _runShell(script, workDir, applyEnvFilters: false);
      }
    } catch (e) {
      stderr.writeln('$name hook failed, continuing: $e');
    }
  }

  /// Runs [command] as a shell command in [workDir].
  Future<void> _runShell(
    String command,
    String workDir, {
    required bool applyEnvFilters,
  }) async {
    final env = _buildSubprocessEnvironment(workDir, applyEnvFilters);
    await Process.run(
      '/bin/sh',
      ['-c', command.trim()],
      workingDirectory: workDir,
      environment: env,
    );
  }

  // ------------------------------------------------------------------
  // JS actions (preJSAction / preCliJSAction / postJSAction)
  // ------------------------------------------------------------------

  /// Executes a JS action via [JsJobRunner] with context and metadata bindings.
  String? _executeJsAction(
    String name,
    String? actionPath,
    String? response,
    String? inputFolderPath,
    String workDir, {
    bool skip = false,
  }) {
    if (skip) {
      stderr.writeln('Skipping $name (skip${_flagName(name)}=true)');
      return null;
    }
    if (actionPath == null || actionPath.trim().isEmpty) return null;
    try {
      final result = jsRunner.runScript(
        scriptPath: actionPath,
        jobParams: _buildJobParams(response, inputFolderPath),
        ticket: _resolvedTicketData ?? ticketData,
        workingDirectory: workDir,
        config: JsRunConfig(
          extraGlobals: _buildExtraGlobals(response, inputFolderPath, workDir),
          contextParams: _metadataContextParams(),
        ),
      );
      _checkPreCliBusinessFailure(name, result);
      return result;
    } catch (e) {
      return _handleJsActionError(name, e);
    }
  }

  /// Loud-mode `preCliJSAction` business-skip check (`false` or `success:false`).
  void _checkPreCliBusinessFailure(String name, String? result) {
    if (!failOnJsActionErrors ||
        name != 'preCliJSAction' ||
        !_isPreCliJsActionFailure(result)) {
      return;
    }
    stderr.writeln('preCliJSAction reported failure — skipping CLI '
        'execution and postJSAction; the JS action is responsible '
        'for its own failure notification.');
    _preCliJsActionSkipped = true;
  }

  /// Error contract for a failed JS action (Java parity, #580/#585).
  String? _handleJsActionError(String name, Object e) {
    if (!failOnJsActionErrors || name == 'preJSAction') {
      stderr.writeln('$name failed, continuing: $e');
      return null;
    }
    if (name == 'postJSAction') {
      throw _JsActionUncaughtException(
        'postJSAction threw an uncaught exception'
        '${_ticketKeySuffix()}: $e',
      );
    }
    stderr.writeln('preCliJSAction threw, treating as setup failure '
        '(skipping CLI execution and postJSAction): $e');
    _preCliSetupThrew = true;
    _preCliJsActionSkipped = true;
    return null;
  }

  /// Java `Teammate.isPreCliJSActionFailure` parity: an explicit `false`
  /// or an object/map containing `success: false`. Any other value
  /// (including `null`/undefined — actions that don't return a structured
  /// result) is treated as success.
  bool _isPreCliJsActionFailure(String? result) {
    if (result == null) return false;
    final trimmed = result.trim();
    if (trimmed == 'false') return true;
    if (!trimmed.startsWith('{')) return false;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map && decoded['success'] == false;
    } on FormatException {
      return false;
    }
  }

  /// `' for ticket <key>'` when ticket data carries a key — used to build
  /// the Java-parity postJSAction error message (epam/dm.ai#585).
  String _ticketKeySuffix() {
    final key = _resolvedTicketData?['key'] ?? ticketData?['key'];
    return key is String && key.isNotEmpty ? ' for ticket $key' : '';
  }

  /// The config key of the skip flag for a JS action name — `preJSAction`
  /// → `PreJSAction` (used as `skip<$suffix>`).
  static String _flagName(String name) =>
      '${name[0].toUpperCase()}${name.substring(1)}';

  // ------------------------------------------------------------------
  // CLI command phase
  // ------------------------------------------------------------------

  /// Runs the response phase: the CLI commands, then `postJSAction`.
  ///
  /// When `preCliJSAction` failed (loud mode), both are skipped — Java
  /// Teammate hard stop: the JS action has already posted its own failure
  /// notification, so nothing downstream should run (epam/dm.ai#580).
  /// Returns the response (or the Java-parity skip label).
  Future<String> _runResponsePhase(String workDir) async {
    if (_preCliJsActionSkipped) {
      return 'Skipped: preCliJSAction reported failure';
    }
    final response = await _executeCliCommands(workDir);
    if (_strictModeMissingOutput) {
      // Java `skipFieldUpdate` parity (epam/dm.ai#622, #409): in strict
      // mode, never run postJSAction against the failed/missing CLI
      // response — a post action like closeQuestionTicket would move
      // tickets to Done on a genuine CLI failure. The error summary in
      // `response` reports the failure instead.
      stderr.writeln(
        'Skipping postJSAction due to missing CLI output file '
        '(requireCliOutputFile=true)',
      );
      return response;
    }
    _executeJsAction(
      'postJSAction',
      params.postJSAction,
      response,
      _inputContextPath,
      workDir,
      skip: params.skipPostJSAction,
    );
    return response;
  }

  /// Builds and executes CLI commands, returning the extracted response.
  ///
  /// When any of `timerJSAction`, `cliExecutionErrorJSAction`, or
  /// `cliOutputLineJSAction` is configured, commands run through the monitored
  /// path ([CliExecutionHelper.executeCommandsWithCallbacks]) so the hooks fire
  /// periodically / per-line / on error. Otherwise the buffered path is used.
  Future<String> _executeCliCommands(String workDir) async {
    final builder = const CliCommandBuilder();
    final resolvedPrompts = params.flattenCliPrompts(
      params.cliPrompts,
      conditionEvaluator: (cond) => _evaluateCliPromptCondition(cond, workDir),
    );
    final finalCommands = builder.buildCommands(
      params.cliCommands,
      params.cliPrompt,
      resolvedPrompts,
      params.cliPromptsByTracker,
      trackerType: propertyReader.getDefaultTracker(),
      workingDirectory: workDir,
    );
    _ensureOutputFolder(workDir);
    final env = _buildSubprocessEnvironment(workDir, true);
    final live = LiveCliOutput();
    final callbacks = _buildCliCallbacks(workDir, live);
    final helper = const CliExecutionHelper();
    _cliResult = callbacks == null
        ? await helper.executeCommands(
            finalCommands,
            workingDirectory: workDir,
            environment: env,
          )
        : await helper.executeCommandsWithCallbacks(
            finalCommands,
            workingDirectory: workDir,
            environment: env,
            callbacks: callbacks,
          );
    return _extractResponse(_cliResult!);
  }

  // ------------------------------------------------------------------
  // Context JS actions (timer / error / line)
  // ------------------------------------------------------------------

  /// Builds CLI-execution callbacks for the timer/error/line JS actions, or
  /// `null` when none are configured.
  CliExecutionCallbacks? _buildCliCallbacks(
    String workDir,
    LiveCliOutput live,
  ) {
    final timer = _buildTimerAction(workDir, live);
    final error = _buildErrorHandler(workDir, live);
    final stop = _buildLineStopPredicate(workDir, live);
    if (timer == null && error == null && stop == null) return null;
    return CliExecutionCallbacks(
      timerAction: timer,
      timerIntervalSeconds: params.timerIntervalSeconds,
      errorHandler: error,
      lineStopPredicate: stop,
      liveOutput: live,
    );
  }

  /// Builds the periodic timer callback (Java `buildTimerRunnable`,
  /// including the #454 `TrackerParams.METADATA` binding).
  void Function()? _buildTimerAction(String workDir, LiveCliOutput live) {
    final action = params.timerJSAction;
    if (action == null || action.trim().isEmpty) return null;
    return () => _runContextJsAction(
          'timerJSAction',
          action,
          workDir,
          {'currentCliOutput': live.value},
          contextParams: _metadataContextParams(),
        );
  }

  /// Builds the CLI-failure callback (Java `buildErrorHandler`).
  void Function(String)? _buildErrorHandler(
      String workDir, LiveCliOutput live) {
    final action = params.cliExecutionErrorJSAction;
    if (action == null || action.trim().isEmpty) return null;
    return (String errorMessage) => _runContextJsAction(
          'cliExecutionErrorJSAction',
          action,
          workDir,
          {'errorMessage': errorMessage, 'currentCliOutput': live.value},
        );
  }

  /// Builds the per-line stop predicate (Java `buildLineStopPredicate`).
  bool Function(String)? _buildLineStopPredicate(
    String workDir,
    LiveCliOutput live,
  ) {
    final action = params.cliOutputLineJSAction;
    if (action == null || action.trim().isEmpty) return null;
    return (String line) {
      final result = _runContextJsAction(
        'cliOutputLineJSAction',
        action,
        workDir,
        {'line': line, 'currentCliOutput': live.value},
      );
      return result?.toLowerCase() == 'true';
    };
  }

  /// Runs a context JS action via [JsJobRunner], injecting [context] globals.
  String? _runContextJsAction(
    String name,
    String actionPath,
    String workDir,
    Map<String, dynamic> context, {
    Map<String, dynamic>? contextParams,
  }) {
    try {
      return jsRunner.runScript(
        scriptPath: actionPath,
        jobParams: _buildJobParams(null, _inputContextPath),
        ticket: _resolvedTicketData ?? ticketData,
        workingDirectory: workDir,
        config: JsRunConfig(
          extraGlobals: _mergeContextGlobals(context, workDir),
          contextParams: contextParams,
        ),
      );
    } catch (e) {
      stderr.writeln('$name failed, continuing: $e');
      return null;
    }
  }

  /// Evaluates a `cliPrompts` section condition script via [_runContextJsAction].
  bool _evaluateCliPromptCondition(String conditionPath, String workDir) {
    final resolvedPath = _resolveConditionPath(conditionPath, workDir);
    final raw = _runContextJsAction(
      'cliPrompts.condition',
      resolvedPath,
      workDir,
      const {},
      contextParams: _metadataContextParams(),
    );
    return isCliPromptConditionMet(raw);
  }

  /// Resolves [conditionPath] against [workDir] or the active agent pack root
  /// inferred from sibling JS action paths when running from an unpacked pack.
  String _resolveConditionPath(String conditionPath, String workDir) {
    final raw = conditionPath.trim();
    if (raw.isEmpty || p.isAbsolute(raw)) return raw;
    final ref = _stripPackScheme(raw);
    final directFile = File(p.join(workDir, ref));
    if (directFile.existsSync()) return directFile.absolute.path;
    final normalized = normalizePackReferencePath(ref);
    final strippedFile = File(p.join(workDir, normalized));
    if (strippedFile.existsSync()) return strippedFile.absolute.path;
    return _resolveInPackRoot(normalized) ?? conditionPath;
  }

  String _stripPackScheme(String ref) {
    if (!ref.startsWith('pack:')) return ref;
    return ref.substring('pack:'.length).replaceFirst(RegExp('^/+'), '');
  }

  String? _resolveInPackRoot(String ref) {
    final packRoot = _inferPackRoot();
    if (packRoot == null) return null;
    final candidate = File(p.normalize(p.join(packRoot.path, ref)));
    if (!p.isWithin(packRoot.path, candidate.path) || !candidate.existsSync()) {
      return null;
    }
    return candidate.absolute.path;
  }

  /// Infers the unpacked pack directory from any configured JS action path.
  Directory? _inferPackRoot() {
    final candidates = [
      params.preJSAction,
      params.preCliJSAction,
      params.postJSAction,
      params.timerJSAction,
    ];
    for (final path in candidates) {
      final root = _findPackRootFor(path);
      if (root != null) return root;
    }
    return null;
  }

  Directory? _findPackRootFor(String? actionPath) {
    if (actionPath == null || !p.isAbsolute(actionPath)) return null;
    var dir = File(actionPath).parent;
    for (var depth = 0; depth < 5; depth++) {
      if (File(p.join(dir.path, packProvenanceFileName)).existsSync() ||
          File(p.join(dir.path, 'manifest.json')).existsSync()) {
        return dir;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// Top-level `metadata` binding merged into `params` for JS hooks (#623).
  Map<String, dynamic>? _metadataContextParams() {
    final md = params.metadata;
    return md == null ? null : {'metadata': md};
  }

  /// Merges the standard JS action globals with action-specific [context].
  Map<String, dynamic> _mergeContextGlobals(
          Map<String, dynamic> context, String workDir) =>
      {..._buildExtraGlobals(null, _inputContextPath, workDir), ...context};

  /// Whether the strict-mode guard applies: `requireCliOutputFile=true` and
  /// the CLI produced no output response — the same condition that makes
  /// [_extractResponse] return the error summary. Java sets `skipFieldUpdate`
  /// from it and skips postJSAction (epam/dm.ai#622, #409).
  bool get _strictModeMissingOutput {
    final result = _cliResult;
    return params.requireCliOutputFile &&
        result != null &&
        !result.hasOutputResponse;
  }

  /// Extracts the response from the CLI result (with [boundedLog] excerpts, gh-192).
  String _extractResponse(CliExecutionResult result) {
    if (params.requireCliOutputFile && !result.hasOutputResponse) {
      return 'CLI command executed but did not produce output file:\n'
          '${boundedLog(result.commandResponses)}';
    }
    if (result.hasOutputResponse) {
      return result.outputResponse!;
    }
    if (result.hasFatalError) {
      return 'CLI command failed (exit code ${result.lastExitCode ?? 'unknown'}) '
          '— outputs/response.md missing; the full session log is excluded '
          'from this response (see the run output). Bounded excerpt:\n'
          '${boundedLog(result.commandResponses)}';
    }
    // Successful run without an output file: the accumulated log is the only
    // response there is — still capped, so no CliAgent response can ever be
    // unbounded (Java would return it in full; gh-192 review thread).
    return boundedLog(result.commandResponses);
  }

  // ------------------------------------------------------------------
  // Environment
  // ------------------------------------------------------------------

  /// Builds the subprocess environment.
  ///
  /// Starts from the OS env, overlays `dmtools.env` from [workDir], then
  /// the per-job `envVariables` overrides. When [applyEnvFilters] is true,
  /// the `excludedEnvVariables`/`excludeEnvVariablesByRegex` filters are
  /// applied (CLI command phase only — script hooks do not filter).
  Map<String, String> _buildSubprocessEnvironment(
    String workDir,
    bool applyEnvFilters,
  ) {
    final workDirEnv = parseEnvFile('$workDir/dmtools.env');
    var env = {
      ...Platform.environment,
      ...workDirEnv,
      ...PropertyReader.resolveEnvVariables(PropertyReader.getOverrides(),
          extraEnv: workDirEnv, basePath: workDir)
    };
    if (applyEnvFilters) {
      env = CliExecutionHelper.filterEnvVariables(
          env, params.excludedEnvVariables, params.excludeEnvVariablesByRegex);
    }
    return env;
  }

  // ------------------------------------------------------------------
  // Filesystem operations
  // ------------------------------------------------------------------

  /// Resolves the working directory (param → existing dir → CWD).
  String _resolveWorkingDirectory() {
    final candidate = workingDirectory ?? params.workingDirectory;
    if (candidate != null && candidate.trim().isNotEmpty) {
      final dir = Directory(candidate);
      if (dir.existsSync()) {
        return dir.absolute.path;
      }
    }
    return Directory.current.absolute.path;
  }

  /// Deletes stale `outputs/response.md` and `output/response.md`.
  void _clearStaleOutputs(String workDir) {
    _deleteFileIfPresent(File('$workDir/outputs/$responseFileName'));
    _deleteFileIfPresent(File('$workDir/output/$responseFileName'));
  }

  /// Deletes [file] when it exists; errors are ignored.
  void _deleteFileIfPresent(File file) {
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  /// Creates the input context folder: `input/<contextId>/`.
  Future<String> _createInputContext(String workDir) async {
    final config = params.effectiveInputContextConfig;
    final resolved = _resolvedTicketData ?? ticketData;
    return TicketInputContextBuilder(
      workDir,
      propertyReader: propertyReader,
      includeAttachments: params.includeAttachments,
      skipAllAttachments: params.skipAllAttachments,
      skipVideoAttachments: params.skipVideoAttachments,
    ).build(
      params.contextId,
      ticketData: resolved,
      config: config,
    );
  }

  /// Resolves ticket data from [ticketData], disk, or `input.ticket`.
  Map<String, dynamic>? _resolveTicketData(String workDir) {
    if (ticketData != null) return ticketData;
    final fromDisk = _readTicketJsonFromDisk(workDir);
    if (fromDisk != null) return fromDisk;
    final ticketKey = params.effectiveInputContextConfig.ticket;
    if (ticketKey != null && ticketKey.isNotEmpty) {
      return TicketSmartSources(propertyReader).fetchTicketByKey(ticketKey);
    }
    return null;
  }

  Map<String, dynamic>? _readTicketJsonFromDisk(String workDir) {
    if (params.contextId.isEmpty) return null;
    final folderName = TicketInputContextBuilder.toInputFolderName(
      params.contextId,
    );
    final candidates = <String>[
      '$workDir/input/$folderName/ticket.json',
      if (folderName != params.contextId)
        '$workDir/input/${params.contextId}/ticket.json',
    ];
    for (final path in candidates) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // Ignore malformed ticket.json and continue.
      }
    }
    return null;
  }

  /// Ensures the `outputs/` folder exists before CLI commands run.
  void _ensureOutputFolder(String workDir) {
    Directory('$workDir/outputs').createSync(recursive: true);
  }

  /// Cleans up the input and outputs folders per params flags.
  ///
  /// Mirrors the Java `finally` block cleanup logic.
  void _performCleanup(String workDir) {
    final inputPath = _inputContextPath;
    if (inputPath != null && params.cleanupInputFolder) {
      _deleteDirectory(Directory(inputPath));
    }
    if (params.cleanupOutputsFolder) {
      _deleteDirectory(Directory('$workDir/outputs'));
      _deleteDirectory(Directory('$workDir/output'));
    }
  }

  /// Recursively deletes [dir] if it exists.
  void _deleteDirectory(Directory dir) {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }

  // ------------------------------------------------------------------
  // JS context building
  // ------------------------------------------------------------------

  /// Builds the job-params map passed as `params.jobParams` to JS actions.
  Map<String, dynamic> _buildJobParams(
    String? response,
    String? inputFolderPath,
  ) {
    return {
      'cliCommands': params.cliCommands,
      if (params.cliPrompt != null) 'cliPrompt': params.cliPrompt,
      if (params.contextId.isNotEmpty) 'contextId': params.contextId,
      if (params.customParams != null) 'customParams': params.customParams,
      if (params.metadata != null) 'metadata': params.metadata,
      if (params.initiator != null) 'initiator': params.initiator,
      if (params.outputType != null) 'outputType': params.outputType,
      if (response != null) 'response': response,
      if (inputFolderPath != null) 'inputFolderPath': inputFolderPath,
    };
  }

  /// Builds the extra top-level JS globals for JS actions.
  ///
  /// Mirrors Java `prepareJsExecutor` `.with()` bindings.
  Map<String, dynamic> _buildExtraGlobals(
    String? response,
    String? inputFolderPath,
    String workDir,
  ) {
    return {
      if (response != null) 'response': response,
      if (inputFolderPath != null) 'inputFolderPath': inputFolderPath,
      'workingDirectory': workDir,
      if (params.customParams != null) 'customParams': params.customParams,
    };
  }
}

/// A JS action crashed with an uncaught exception while
/// [CliAgent.failOnJsActionErrors] is on — Java Teammate epam/dm.ai#585
/// parity: the message carries the full JS error text so the failing CI
/// step shows what actually broke.
class _JsActionUncaughtException implements Exception {
  const _JsActionUncaughtException(this.message);

  /// The full error text (action name, ticket, JS error).
  final String message;

  @override
  String toString() => message;
}
