/// Bridge between JS host functions and the Dart MCP tool registry.
///
/// Registers global JS functions on a [QuickjsRuntime]:
/// - `executeToolViaJava(toolName, args)` — generic tool dispatch, the
///   equivalent of the Java `JobJavaScriptBridge.executeToolViaJava`.
/// - `file_read({path})` — synchronous file reader returning the raw file
///   content as a plain JS string (mirrors the Java bridge contract that
///   testRunner.js and configLoader.js rely on: `content.trim()`).
/// - `set_env_variable(propertyName, envVarName)` — no-op (Phase 1 handles
///   overrides); validates its argument count for Java parity.
/// - `console.log/error/warn/info/debug` — prints to Dart's stdout/stderr.
///
/// File-system and CLI tools execute synchronously via `dart:io` — the
/// [SyncToolDispatcher] delegates them back through the non-HTTP handler.
/// HTTP tools (jira, github, …) dispatch synchronously via curl subprocess —
/// see [SyncToolDispatcher].
library;

import 'dart:convert';
import 'dart:io';

import '../config/env_file_parser.dart';
import '../config/property_reader.dart';
import '../config/property_reader_getters.dart';
import '../integrations/cli/allowed_base.dart';
import '../integrations/cli/cli_tools.dart';
import '../mcp/tool_registry.dart';
import 'package:path/path.dart' as p;
import 'package:quickjs_runtime/quickjs_runtime.dart';

import 'loader_read_host.dart';
import 'sync_tool_dispatcher.dart';

part 'tool_bridge_console.dart';

/// Registers JS host functions backed by the Dart MCP tool registry.
class ToolBridge {
  final ToolRegistry _registry;
  final String? _workingDirectory;
  final String? _consolePrefix;

  /// Creates a bridge backed by [registry].
  ///
  /// Relative file paths in tool calls resolve against [workingDirectory]
  /// (defaults to [Directory.current]). [consolePrefix] is prepended to
  /// every `console.*` line (worker log attribution on the `runAsync`
  /// pool); null keeps the default unprefixed output.
  ToolBridge({
    required ToolRegistry registry,
    String? workingDirectory,
    String? consolePrefix,
  })  : _registry = registry,
        _workingDirectory = workingDirectory,
        _consolePrefix = consolePrefix;

  /// The single tool dispatcher shared by every call through this bridge.
  ///
  /// Holds the per-integration sync tool sets and their config
  /// [PropertyReader]; one instance per bridge so repeated tool calls reuse
  /// the loaded configuration (and its cached `dmtools.env` reads) instead
  /// of rebuilding both on every call.
  late final SyncToolDispatcher dispatcher = SyncToolDispatcher(
    PropertyReader(),
    nonHttpHandler: _dispatchNonHttp,
  );

  /// CLI executor for the JS-bridge `cli_execute_command` path: supplies the
  /// base whitelist plus the `CLI_ALLOWED_COMMANDS` extension.
  late final CliToolExecutor _cliExecutor = CliToolExecutor(PropertyReader());

  /// Registers `executeToolViaJava`, `file_read`, `set_env_variable`, and
  /// the `console` object as globals on [runtime].
  ///
  /// The host functions are registered under private `__…Host` names and
  /// wrapped by the JS bootstrap under the public global names
  /// (`__loaderReadHost` is the exception: the require loader captures it
  /// into its closure and deletes the global, gh-369): FFI host functions
  /// cannot throw into JS (stray Dart exceptions surface as JS
  /// `undefined`), so argument-validation failures return a
  /// `{'__jsError': …}` sentinel that the JS wrapper rethrows as a real
  /// JS `Error` — mirroring Java `IllegalArgumentException` propagation.
  ///
  /// [wireEngine] calls this in two steps — [registerHostFunctions] before
  /// the require loader, [installHostWrappers] after the tool wrappers —
  /// so the direct `file_read` host function (returning the raw content
  /// string) takes
  /// precedence over any generated wrapper that dispatches via
  /// `executeToolViaJava`.
  void registerOn(QuickjsRuntime runtime) {
    registerHostFunctions(runtime);
    installHostWrappers(runtime);
  }

  /// Step 1 of [registerOn]: registers the raw FFI host functions and the
  /// console. Runs FIRST in [wireEngine] so the require loader can capture
  /// `__loaderReadHost` into its closure (and delete the global) at
  /// install time (gh-369).
  void registerHostFunctions(QuickjsRuntime runtime) {
    runtime.registerHostFunction('__executeToolViaJavaHost', _dispatchToolCall);
    runtime.registerHostFunction('__fileReadHost', _fileReadHost);
    runtime.registerHostFunction('__loaderReadHost', loaderReadHost);
    runtime.registerHostFunction('__setEnvVariableHost', _setEnvVariable);
    _registerConsole(runtime, _consolePrefix);
  }

  /// Step 2 of [registerOn]: evaluates the JS bootstrap wrapping the host
  /// functions under their public global names. Runs LAST in [wireEngine]
  /// (after the generated tool wrappers) so the direct `file_read` host
  /// function keeps precedence over any generated wrapper.
  void installHostWrappers(QuickjsRuntime runtime) {
    runtime.eval(hostFunctionsBootstrap, filename: '<host_functions>');
  }

  /// Dispatch table for synchronous file tool execution.
  ///
  /// Every entry resolves its paths through [_sandboxPath] (gh-365, Java
  /// `FileTools` parity) before touching the filesystem — see the
  /// sync-operations section comment below.
  late final Map<String, String Function(Map<String, dynamic>)> _fileFns = {
    'file_read': (a) => _readFile(a['path'] as String),
    'file_write': (a) =>
        _writeFile(a['path'] as String, a['content'] as String),
    'file_list': (a) => _listDir(a['path'] as String),
    'file_exists': (a) => _exists(a['path'] as String),
    'file_delete': (a) => _delete(a['path'] as String),
    'file_copy': (a) => _copy(a['source'] as String, a['dest'] as String),
    'file_move': (a) => _move(a['source'] as String, a['dest'] as String),
    'file_mkdir': (a) => _mkdir(a['path'] as String),
    'file_read_lines': (a) => _readLines(a['path'] as String),
    'file_write_lines': (a) => _writeLines(a['path'] as String, a['lines']),
    'file_append': (a) => _append(a['path'] as String, a['content'] as String),
    'file_info': (a) => _info(a['path'] as String),
  };

  /// Handles `executeToolViaJava(toolName, args)` calls from JS wrappers.
  ///
  /// The C bridge marshals the call arguments as JSON: 2+ JS args as an
  /// array (`[toolName, argsObj]`), a single arg as-is, and none as an
  /// unparseable object literal (see [_decodeArgs]). Java
  /// `ExecuteToolProxy` parity: at least the tool name is required (a bare
  /// tool name executes with empty args); fewer surfaces the `__jsError`
  /// sentinel.
  ///
  /// Tool-execution failures also surface as the `__jsError` sentinel (rethrown
  /// as a JS `Error` by the bootstrap) — Java `JobJavaScriptBridge` parity: a
  /// failed call throws into the script, which agent scripts catch and react
  /// to; it never resolves to a value a script could mistake for tool data.
  String _dispatchToolCall(String argsJson) {
    final parsed = _decodeArgs(argsJson);
    if (parsed is String) {
      return _timed(
        parsed,
        () => _toolCallResult(() => _execute(parsed, const {})),
      );
    }
    if (parsed is List && parsed.length >= 2 && parsed[0] is String) {
      final toolName = parsed[0] as String;
      return _timed(
        toolName,
        () => _toolCallResult(
          () => _execute(toolName, _castArgs(parsed[1])),
        ),
      );
    }
    return _jsError(
      'executeToolViaJava requires at least 1 argument: toolName',
    );
  }

  /// Runs one dispatched tool call, printing the elapsed wall time after
  /// it returns. The generated JS wrappers log `Calling tool <name>`
  /// before the call; this closes the pair so slow calls (tracker
  /// hydration, CLI, HTTP) are visible in the plain trace.
  String _timed(String toolName, String Function() run) {
    final sw = Stopwatch()..start();
    try {
      return run();
    } finally {
      stdout.writeln('Tool $toolName finished in '
          '${sw.elapsedMilliseconds}ms');
    }
  }

  /// Runs one tool call for the `executeToolViaJava` host function and
  /// converts failures into the `__jsError` sentinel.
  ///
  /// Failures arrive two ways: a Dart exception thrown by an executor, or a
  /// single-key `{"error": …}` envelope (the [SyncToolDispatcher] failure
  /// convention — unconfigured integration, unknown tool, transport error).
  /// Both become `Tool execution failed: <message>`, the wording the Java
  /// bridge uses. Successful results pass through untouched; a multi-key
  /// object that happens to carry an `error` field is a remote API body and
  /// passes through too.
  String _toolCallResult(String Function() run) {
    final String result;
    try {
      result = run();
    } catch (e) {
      return _jsError('Tool execution failed: $e');
    }
    final decoded = _decodeArgs(result);
    final isErrorEnvelope =
        decoded is Map && decoded.length == 1 && decoded['error'] != null;
    if (isErrorEnvelope) {
      return _jsError('Tool execution failed: ${decoded['error']}');
    }
    return result;
  }

  /// Handles direct `file_read({path})` calls from JS test scripts.
  ///
  /// Returns the file content as a plain JSON string (the C bridge
  /// unmarshals it back to a JS string), or JS `null` when the file cannot
  /// be read — the Java bridge contract testRunner.js and configLoader.js
  /// depend on (`content && content.trim()`).
  ///
  /// gh-365: a path outside the sandbox (Java `FileTools.readFile` parity)
  /// is logged ("Path traversal attempt blocked") and answered with null —
  /// the same observable result as a missing file, never a thrown error.
  ///
  /// Logs the call args first, like every other tool: in Java `file_read`
  /// is a generated wrapper that logs its call, but here the direct host
  /// replaces that wrapper.
  String _fileReadHost(String argsJson) {
    final parsed = _decodeArgs(argsJson);
    // Java `FileTools.readFile` parity (gh-401): accepts the string form
    // `file_read('a.txt')` and the object form `file_read({path})`. Any
    // other shape (number, array, object without a string `path`, no
    // argument, null) is a wrong call: it throws, never an empty string.
    final path = _parseFileReadPath(parsed);
    if (path == null) {
      return _jsError(
        'file_read expects a path string or {path: <string>} as its '
        'argument (got ${parsed == null ? 'no argument' : jsonEncode(parsed)})',
      );
    }
    stdout.writeln('Calling tool file_read with args: '
        '${jsonEncode(parsed is Map ? parsed : {'path': path})}');
    return _timed('file_read', () => _fileReadResult(path));
  }

  /// gh-401 argument contract: the string form `file_read('a.txt')` or the
  /// object form `file_read({path})`. Returns null for any other shape
  /// (the caller answers with the _jsError envelope).
  String? _parseFileReadPath(Object? parsed) {
    if (parsed is String) return parsed;
    if (parsed is Map && parsed['path'] is String) {
      return parsed['path'] as String;
    }
    return null;
  }

  /// Read body: empty path answers null (Java parity), sandbox refusal
  /// answers null, unreadable file answers null; success wraps the content
  /// as a JSON string. Never throws (the JS bridge surface is total).
  String _fileReadResult(String path) {
    if (path.isEmpty) {
      stderr.writeln('file_read: empty path');
      return 'null';
    }
    final String resolved;
    try {
      // gh-367: the direct host is the read flavor — require() reads
      // pack modules through here (Java `readFile` parity).
      resolved = _sandboxReadPath(path);
    } catch (e) {
      stderr.writeln('file_read: $e');
      return 'null';
    }
    try {
      return jsonEncode(File(resolved).readAsStringSync());
    } catch (_) {
      return 'null';
    }
  }

  /// `SetEnvVariableProxy` parity — `set_env_variable(propertyName,
  /// envVarName)` merges the value into the PropertyReader override map.
  /// The override reaches subsequent `cli_execute_command` children (env
  /// injection applies [PropertyReader.getOverrides] last) and
  /// `PropertyReader.getValue` — matching Java, where the proxy mutates
  /// the JVM-wide property map the CLI executor reads.
  ///
  /// The C bridge marshals a single JS argument as-is and none as an
  /// unparseable object literal, so anything but a 2+ element array fails
  /// validation via the `__jsError` sentinel.
  String _setEnvVariable(String argsJson) {
    final parsed = _decodeArgs(argsJson);
    if (parsed is List && parsed.length >= 2) {
      final name = parsed[0]?.toString();
      final value = parsed[1]?.toString();
      if (name != null && name.isNotEmpty && value != null) {
        PropertyReader.setOverride(name, value);
      }
      return _successJson;
    }
    return _jsError(
      'set_env_variable requires 2 arguments: propertyName, envVarName',
    );
  }

  /// Executes [toolName] with [args], returning the JSON result string.
  ///
  /// This is the same dispatch path used by `executeToolViaJava` from JS,
  /// exposed for direct CLI invocation (`dmtools <tool> '<json>'`). Returns
  /// an `{"error": ...}` JSON object when the tool is unknown or dispatch
  /// fails.
  String execute(String toolName, Map<String, dynamic> args) =>
      _execute(toolName, args);

  /// Routes [toolName] through [dispatcher], the single entry point.
  ///
  /// HTTP tools (jira, github, …) dispatch via curl; file-system and CLI
  /// tools delegate back to [_dispatchNonHttp] for direct `dart:io` execution.
  String _execute(String toolName, Map<String, dynamic> args) {
    // Java JobJavaScriptBridge.executeToolFromJS parity (dm.ai #577):
    // vendor-agnostic aliases (tracker_*, source_code_*) resolve on every
    // call — explicit GitHub key formats first, then DEFAULT_TRACKER /
    // DEFAULT_SOURCE_CODE via the property chain, then key-format
    // detection — so agent scripts written against the tracker_* family
    // run unchanged on any configured backend. Canonical names resolve to
    // themselves and dispatch exactly as before.
    final resolved = _registry.resolveToolAlias(
      toolName,
      keyHint: _extractKeyHint(args),
      defaultTracker: _propertyReader.getDefaultTracker(),
      defaultSourceCode: _propertyReader.getDefaultSourceCode(),
    );
    final tool = resolved == null ? null : _registry.getTool(resolved);
    if (tool == null) {
      return _err('Unknown tool: $toolName');
    }
    return dispatcher.execute(tool.name, tool.applyParamAliases(args)) ??
        _err('Tool not available: $toolName');
  }

  /// Property source for per-call alias routing (`DEFAULT_TRACKER` /
  /// `DEFAULT_SOURCE_CODE`) — a shared instance so cached `dmtools.env`
  /// reads persist across tool calls.
  late final PropertyReader _propertyReader = PropertyReader();

  /// Extracts a ticket/issue key hint from tool call args — Java
  /// `JobJavaScriptBridge.extractKeyHint` parity (dm.ai #577): the first
  /// present of `key`, `ticketKey`, `ticket`, `issueKey`, `id`, used for
  /// vendor detection when routing `tracker_*` aliases.
  String? _extractKeyHint(Map<String, dynamic> args) {
    for (final field in const [
      'key',
      'ticketKey',
      'ticket',
      'issueKey',
      'id'
    ]) {
      final value = args[field];
      if (value != null) return value.toString();
    }
    return null;
  }

  /// Delegates non-HTTP tools (file-system, CLI) to their sync executors.
  String _dispatchNonHttp(String toolName, Map<String, dynamic> args) {
    final tool = _registry.getTool(toolName);
    if (tool == null) return _err('Unknown tool: $toolName');
    switch (tool.integration) {
      case 'file':
        return _executeFileTool(toolName, args);
      case 'cli':
        return _executeCliTool(toolName, args);
      default:
        return _err('Unsupported non-HTTP integration: ${tool.integration}');
    }
  }

  /// Dispatches a file tool synchronously by name.
  String _executeFileTool(String name, Map<String, dynamic> args) {
    final fn = _fileFns[name];
    return fn != null ? fn(args) : _err('Unknown file tool: $name');
  }

  /// Executes JS-bridge CLI tools. `cli_execute_command` follows Java
  /// `CliCommandExecutor` parity exactly: the command is a full command LINE
  /// whose first token is whitelisted (base set + `CLI_ALLOWED_COMMANDS`);
  /// the line runs through a shell temp script (`/bin/sh`; `cmd.exe /c` on
  /// Windows) and trimmed stdout is returned as a plain string. Non-zero
  /// exit, spawn failure, or a whitelist violation surfaces as the
  /// `__jsError` sentinel (Java SecurityException / CliCommandFailedException
  /// parity) and is rethrown as a JS `Error`. The Dart-only extras
  /// (`cli_execute_command_with_env`) keep their legacy `command` + `args`
  /// array semantics.
  String _executeCliTool(String toolName, Map<String, dynamic> args) {
    if (toolName != 'cli_execute_command') {
      return _executeLegacyCliTool(args);
    }
    final command = (args['command'] as String?)?.trim();
    if (command == null || command.isEmpty) {
      return _err('Command cannot be null or empty');
    }
    final firstWord = command.split(RegExp(r'\s+')).first.toLowerCase();
    final allowed = _cliExecutor.allowedCommands.toList()..sort();
    if (!allowed.contains(firstWord)) {
      return _err(
          'Command not allowed. Whitelisted commands: ${allowed.join(', ')}');
    }
    try {
      final workDir =
          _resolveCliWorkingDir(args['workingDirectory'] as String?);
      return _runCommandLine(command, workDir);
    } catch (e) {
      // SecurityException parity for the allowed-base validation failure.
      return _err(e.toString());
    }
  }

  /// Legacy executor for the Dart-only `cli_execute_command_with_env`:
  /// [args] carry a `command` executable plus a separate `args` array.
  /// Returns a `{stdout, stderr, exitCode}` JSON object (pre-parity shape,
  /// kept so the Dart-only tool surface does not regress).
  String _executeLegacyCliTool(Map<String, dynamic> args) {
    final command = args['command'] as String?;
    if (command == null) return _err('missing command argument');
    try {
      final cliArgs = args['args'] is List
          ? (args['args'] as List).cast<String>().toList()
          : const <String>[];
      final result = Process.runSync(command, cliArgs);
      return jsonEncode({
        'stdout': result.stdout.toString(),
        'stderr': result.stderr.toString(),
        'exitCode': result.exitCode,
      });
    } catch (e) {
      return _err(e.toString());
    }
  }

  /// Runs the whitelisted [command] line through a shell and returns its
  /// trimmed stdout.
  ///
  /// Java `CommandLineUtils.runCommand` parity: the line is written to a temp
  /// script (avoids shell-escaping issues) and executed with `/bin/sh`, the
  /// real exit code is propagated, and a non-zero exit fails the call.
  ///
  /// This path captures synchronously and cannot mirror output live: the JS
  /// `executeToolViaJava` contract is a synchronous FFI host call, and
  /// `dart:io` has no synchronous streaming API (`Process.runSync` is the
  /// only blocking run). The live stderr mirroring lives on the async
  /// process paths — the CliAgent command phases and the direct CLI tool
  /// executor — see `process_output_tee.dart`.
  String _runCommandLine(String command, String? workDir) {
    final env = _cliProcessEnv(workDir);
    try {
      final result = Platform.isWindows
          ? Process.runSync('cmd.exe', ['/c', '$command 2>&1'],
              workingDirectory: workDir, environment: env)
          : _runShellScript(command, workDir, env);
      // Java merges stdout and stderr (`redirectErrorStream(true)`), so the
      // script redirects the whole command group into stdout.
      final output = result.stdout.toString().trim();
      if (result.exitCode != 0) {
        return _err('Command execution failed (exit code '
            '${result.exitCode}): $output');
      }
      // The FFI host callback marshals through JSON, so a plain-string
      // result (Java `executeCommand` parity) is returned JSON-encoded and
      // surfaces to JS as an unquoted string.
      return jsonEncode(output);
    } catch (e) {
      return _err('Command execution failed: $e');
    }
  }

  /// Writes [command] to a temp shell script and runs it with `/bin/sh`.
  ProcessResult _runShellScript(
      String command, String? workDir, Map<String, String> env) {
    final script = File('${Directory.systemTemp.path}/dmtools_cli_'
        '${DateTime.now().microsecondsSinceEpoch}.sh');
    script.writeAsStringSync('{\n$command\n} 2>&1\n');
    try {
      return Process.runSync('/bin/sh', [script.path],
          workingDirectory: workDir, environment: env);
    } finally {
      try {
        script.deleteSync();
      } catch (_) {}
    }
  }

  /// Resolves the working directory per Java `resolveWorkingDirectory`:
  /// an explicit [workingDirectory] that exists wins (validated within the
  /// allowed bases); otherwise the git root of the job base directory, then
  /// the base itself — the Dart stand-in for the process cwd a Java CLI
  /// launched from that directory would inherit. Relative paths resolve
  /// against the base.
  String _resolveCliWorkingDir(String? workingDirectory) {
    final base = _workingDirectory ?? Directory.current.path;
    if (workingDirectory != null && workingDirectory.trim().isNotEmpty) {
      final specified = Directory(workingDirectory.trim());
      final resolved = specified.isAbsolute
          ? specified
          : Directory('$base/${specified.path}');
      if (resolved.existsSync()) {
        validateWithinAllowedBase(resolved.absolute.path, base);
        return resolved.path;
      }
    }
    return gitRepositoryRoot(base) ?? base;
  }

  /// Java `loadEnvironmentVariables` + `CommandLineUtils.runCommand` parity:
  /// the command runs through a `ProcessBuilder`, whose environment starts
  /// as a copy of the PARENT process environment, then merges the extras on
  /// top (`environment().putAll(additionalEnv)`) — so children inherit
  /// everything the host exported (e.g. `FA_LOG_FILE` for the run-agent
  /// trace), with GIT_PAGER/GIT_TERMINAL_PROMPT defaults, the extended PATH,
  /// `dmtools.env` from the working directory and job-level overrides
  /// applied over it in that order.
  Map<String, String> _cliProcessEnv(String? workDir) {
    final env = Map<String, String>.from(Platform.environment);
    env['GIT_PAGER'] = 'cat';
    env['GIT_TERMINAL_PROMPT'] = '0';
    var path = env['PATH'] ?? '';
    for (final dir in const [
      '/usr/local/bin',
      '/opt/homebrew/bin',
      '/usr/bin',
      '/bin'
    ]) {
      if (!path.contains(dir)) path = '$path:$dir';
    }
    env['PATH'] = path;
    final workDirEnv = workDir != null
        ? parseEnvFile('$workDir/dmtools.env')
        : const <String, String>{};
    env.addAll(workDirEnv);
    env.addAll(
      PropertyReader.resolveEnvVariables(
        PropertyReader.getOverrides(),
        extraEnv: workDirEnv,
        basePath: workDir,
      ),
    );
    return env;
  }

  // ── Synchronous file operations ────────────────────────────────────────
  //
  // Every operation resolves its path through [_sandboxPath] (gh-365, Java
  // `FileTools` parity): relative paths resolve against the job base and
  // anything outside the base / git root / system tmpdir throws into the
  // per-operation catch and surfaces as the standard `{"error": …}`
  // envelope — which the `executeToolViaJava` path rethrows as a JS
  // `Error`, Java `SecurityException` semantics.
  //
  // gh-367: read-flavored operations resolve through [_sandboxReadPath]
  // instead — the same containment check plus the
  // `DMTOOLS_FILE_READ_ALLOWED_PATHS` globs (Java `isAllowedByConfig`
  // parity), so the SM pack's `require()` chain reads its own modules
  // under `~/.dmtools/packs`. Write flavors keep [_sandboxPath]: Java's
  // `writeFile`/`deleteFile` never consult the config.

  /// Sandbox resolver for the whole `file_*` bridge family: shares
  /// [resolveWithinAllowedBase] with the async FileToolExecutor surface so
  /// the two cannot drift apart on a security-flavored behavior again.
  String _sandboxPath(String path) => resolveWithinAllowedBase(
      path, _workingDirectory ?? Directory.current.path);

  /// Sandbox resolver for read-flavored operations: containment plus the
  /// configured allow-list, read fresh from [PropertyReader] per call
  /// (Java `new PropertyReader().getFileReadAllowedPaths()` parity).
  String _sandboxReadPath(String path) => resolveWithinAllowedBase(
      path, _workingDirectory ?? Directory.current.path,
      configuredAllowedPaths: PropertyReader().getFileReadAllowedPaths());

  String _readFile(String path) {
    try {
      return jsonEncode(
          {'content': File(_sandboxReadPath(path)).readAsStringSync()});
    } catch (e) {
      return _err(e.toString());
    }
  }

  /// gh-361: parent-directory behavior of Java `FileTools.writeFile` —
  /// creates missing parent directories before writing, so a write to a
  /// nested non-existent path (e.g. the token-usage reporter's
  /// `outputs/token_usage/` cache) succeeds instead of failing with
  /// `PathNotFoundException`.
  ///
  /// gh-365: parity now includes the traversal sandbox — the parent
  /// creation only happens for paths that resolved inside the allowed
  /// bases (see [_sandboxPath]), so the gh-361 shortcut can no longer
  /// materialize directories outside the job base.
  String _writeFile(String path, String content) {
    try {
      final resolved = _sandboxPath(path);
      final parent = File(resolved).parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }
      File(resolved).writeAsStringSync(content);
      return _successJson;
    } catch (e) {
      return _err(e.toString());
    }
  }

  String _listDir(String path) {
    try {
      // Java FileTools.listFiles parity (dm.ai#635): entries are absolute,
      // normalized, and sorted.
      final entries = Directory(_sandboxReadPath(path))
          .listSync()
          .map((e) => p.normalize(e.path))
          .toList()
        ..sort();
      return jsonEncode({'entries': entries});
    } catch (e) {
      return _err(e.toString());
    }
  }

  String _exists(String path) {
    try {
      final resolved = _sandboxReadPath(path);
      final exists =
          File(resolved).existsSync() || Directory(resolved).existsSync();
      return jsonEncode({'exists': exists});
    } catch (e) {
      return _err(e.toString());
    }
  }

  String _delete(String path) {
    try {
      final file = File(_sandboxPath(path));
      if (file.existsSync()) {
        file.deleteSync();
        return '{"deleted":true}';
      }
      return '{"deleted":false}';
    } catch (e) {
      return _err(e.toString());
    }
  }

  String _copy(String source, String dest) {
    try {
      File(_sandboxPath(source)).copySync(_sandboxPath(dest));
      return _successJson;
    } catch (e) {
      return _err(e.toString());
    }
  }

  String _move(String source, String dest) {
    try {
      File(_sandboxPath(source)).renameSync(_sandboxPath(dest));
      return _successJson;
    } catch (e) {
      return _err(e.toString());
    }
  }

  String _mkdir(String path) {
    try {
      Directory(_sandboxPath(path)).createSync(recursive: true);
      return _successJson;
    } catch (e) {
      return _err(e.toString());
    }
  }

  String _readLines(String path) {
    try {
      final lines = File(_sandboxReadPath(path)).readAsLinesSync();
      return jsonEncode({'lines': lines});
    } catch (e) {
      return _err(e.toString());
    }
  }

  String _writeLines(String path, dynamic lines) {
    try {
      final list = (lines as List).cast<String>();
      File(_sandboxPath(path)).writeAsStringSync(list.join('\n'));
      return _successJson;
    } catch (e) {
      return _err(e.toString());
    }
  }

  String _append(String path, String content) {
    try {
      File(_sandboxPath(path))
          .writeAsStringSync(content, mode: FileMode.append);
      return _successJson;
    } catch (e) {
      return _err(e.toString());
    }
  }

  String _info(String path) {
    try {
      final resolved = _sandboxReadPath(path);
      final type = FileSystemEntity.typeSync(resolved);
      final exists = type != FileSystemEntityType.notFound;
      if (!exists) {
        return jsonEncode({'exists': false, 'isDirectory': false, 'size': 0});
      }
      final stat = FileStat.statSync(resolved);
      return jsonEncode({
        'exists': true,
        'isDirectory': type == FileSystemEntityType.directory,
        'size': stat.size,
      });
    } catch (e) {
      return _err(e.toString());
    }
  }
}

/// JS bootstrap that builds the public host-function globals over the
/// private `__…Host` functions registered by [ToolBridge.registerOn].
///
/// FFI host functions cannot throw into JS, so validation failures return
/// a `{'__jsError': <message>}` sentinel object; the wrapper turns that
/// into a real JS `Error` (Java `IllegalArgumentException` parity). All
/// other results pass through untouched.

/// JSON body returned by host functions that only signal success.
const _successJson = '{"success":true}';
// ── Helpers ─────────────────────────────────────────────────────────────

Map<String, dynamic> _castArgs(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};

/// Decodes a host-call argument payload.
///
/// The C bridge marshals a JS call with **no** arguments as a bare object
/// whose string form (`[object Object]`) is not JSON — decoded here as
/// `null` so callers treat it as "no arguments" instead of crashing (a
/// crashed host callback surfaces as JS `undefined`, losing the error).
dynamic _decodeArgs(String argsJson) {
  try {
    return jsonDecode(argsJson);
  } on FormatException {
    return null;
  }
}

String _err(String message) => jsonEncode({'error': message});

/// Sentinel body for host-function argument validation: a JS bootstrap
/// wrapper turns this into a real JS `Error` (see [_hostFunctionBootstrap]).
String _jsError(String message) => jsonEncode({'__jsError': message});
