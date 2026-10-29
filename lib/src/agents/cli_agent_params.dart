/// Parameters for [CliAgent] — Dart port of Java `CliAgentParams`.
///
/// Extends the `TrackerParams` contract (outputType, envVariables, metadata,
/// preJSAction, postJSAction, ...) but does not require `inputJql`. The job
/// is designed to run CLI agents in a lightweight, ticket-agnostic mode.
///
/// Every key, type, and default matches the Java contract exactly — see
/// the parameter table in GOAL.md → Phase 5.
library;

import 'input_context_config.dart';

/// Parameters for the [CliAgent] job.
///
/// Ported from Java `CliAgentParams` which extends `TrackerParams`.
/// The `cliPrompts` field accepts both a flat string array (backward
/// compatibility) and a structured config (array of strings and/or
/// `{"id":"…","prompts":[…]}` section objects).
///
/// Fields are mutable so that [fromJson] and test code can set them
/// without a 26-parameter constructor (quality-gate max-params = 6).
class CliAgentParams {
  /// Creates params with all defaults applied.
  ///
  /// Use [CliAgentParams.fromJson] for production, or set fields directly
  /// via cascade syntax in tests:
  /// ```dart
  /// CliAgentParams()..cliCommands = ['echo']..setup = 'make setup';
  /// ```
  CliAgentParams();

  /// Optional smart input context (plain ticket-key string or config object).
  dynamic input;

  /// CLI commands to execute — required for the job to do anything.
  List<String> cliCommands = const [];

  /// Single base CLI prompt (appended to every command via temp file).
  String? cliPrompt;

  /// Structured CLI prompts — array of strings and/or section objects.
  dynamic cliPrompts;

  /// Tracker-specific CLI prompts, keyed by tracker type name.
  Map<String, List<String>>? cliPromptsByTracker;

  /// Setup hook — shell command or `.js` path (runs first).
  String? setup;

  /// Cache hook — shell command or `.js` path (runs after postJSAction).
  String? cache;

  /// Reset hook — shell command or `.js` path (always runs, even on failure).
  String? reset;

  /// Pre-CLI JS action path (runs before cliCommands).
  String? preCliJSAction;

  /// Whether to clean up the input folder after execution. Default: `true`.
  bool cleanupInputFolder = true;

  /// Whether to require an output file for success. Default: `false`.
  bool requireCliOutputFile = false;

  /// Working directory for command execution. Default: CWD.
  String? workingDirectory;

  /// Exact env variable names to exclude from the subprocess.
  List<String>? excludedEnvVariables;

  /// Regex patterns; matching env variable names are excluded.
  List<String>? excludeEnvVariablesByRegex;

  /// Timer JS action path, fired periodically during CLI execution.
  String? timerJSAction;

  /// Timer interval in seconds. Default: `60`.
  int timerIntervalSeconds = 60;

  /// Whether to clean up the outputs folder after execution.
  bool cleanupOutputsFolder = false;

  /// JS action path fired when a CLI command fails.
  String? cliExecutionErrorJSAction;

  /// JS action path fired for each output line; returning true stops.
  String? cliOutputLineJSAction;

  /// Whether to skip the `preJSAction` hook. Default: `false`.
  bool skipPreJSAction = false;

  /// Whether to skip the `preCliJSAction` hook. Default: `false`.
  bool skipPreCliJSAction = false;

  /// Whether to skip the `postJSAction` hook. Default: `false`.
  bool skipPostJSAction = false;

  /// Whether to download ticket attachments into the input folder. Default: `true`.
  bool includeAttachments = true;

  /// Whether to skip all ticket attachments. Default: `false`.
  bool skipAllAttachments = false;

  /// Whether to skip video attachments when [includeAttachments] is true. Default: `false`.
  bool skipVideoAttachments = false;
  // --- Inherited from TrackerParams ---

  /// Output type — `comment`, `field`, `creation`, or `none`.
  String? outputType;

  /// Per-job environment variable overrides.
  Map<String, String>? envVariables;

  /// Job metadata (contains `contextId`, etc.).
  Map<String, dynamic>? metadata;

  /// Job initiator.
  String? initiator;

  /// Pre-JS action path (runs after setup, before preCliJSAction).
  String? preJSAction;

  /// Post-JS action path (runs after cliCommands, before cache).
  String? postJSAction;

  /// Custom parameters exposed to JS actions as `customParams`.
  Map<String, dynamic>? customParams;

  /// Parsed smart input context configuration (`InputContextConfig`).
  InputContextConfig? inputContextConfig;

  /// Returns the effective [InputContextConfig] for `TicketInputContextBuilder`.
  InputContextConfig get effectiveInputContextConfig =>
      inputContextConfig ??
      InputContextConfig.fromJson({
        if (input != null) 'input': input,
        'includeAttachments': includeAttachments,
        'skipAllAttachments': skipAllAttachments,
        'skipVideoAttachments': skipVideoAttachments,
      });

  /// Returns the context ID from metadata, `input.ticket` / `input` string, or
  /// `"cli-agent"` fallback.
  ///
  /// Mirrors `CliAgent.getContextId()`.
  String get contextId {
    final md = metadata;
    if (md != null && md['contextId'] is String) {
      final id = md['contextId'] as String;
      if (id.isNotEmpty) return id;
    }
    final ticketFromInput = effectiveInputContextConfig.ticket;
    if (ticketFromInput != null && ticketFromInput.isNotEmpty) {
      return ticketFromInput;
    }
    return 'cli-agent';
  }

  /// Returns `cliPrompts` as a flat string array, or `null`.
  ///
  /// Handles both plain string arrays and structured config (objects with
  /// `id`/`prompt`/`prompts`/`condition` fields), matching the Java
  /// `CliPromptsConfig.toStringArray()`.
  List<String>? get cliPromptsAsArray => flattenCliPrompts(cliPrompts);

  /// Flattens `cliPrompts` using an optional [conditionEvaluator] for
  /// sections that declare a `condition` script path.
  List<String>? flattenCliPrompts(
    dynamic value, {
    bool Function(String condition)? conditionEvaluator,
  }) =>
      _flattenCliPrompts(value, conditionEvaluator: conditionEvaluator);

  /// Creates params from a JSON map (the `params` block of a job config).
  factory CliAgentParams.fromJson(Map<String, dynamic> json) {
    return CliAgentParams()
      ..input = json['input']
      ..cliCommands = _parseStringList(json['cliCommands'])
      ..cliPrompt = _parseString(json['cliPrompt'])
      ..cliPrompts = json['cliPrompts']
      ..cliPromptsByTracker =
          _parsePromptsByTracker(json['cliPromptsByTracker'])
      ..setup = _parseString(json['setup'])
      ..cache = _parseString(json['cache'])
      ..reset = _parseString(json['reset'])
      ..preCliJSAction = _parseString(json['preCliJSAction'])
      ..cleanupInputFolder = _parseBool(json['cleanupInputFolder'], true)
      ..requireCliOutputFile = _parseBool(json['requireCliOutputFile'], false)
      ..workingDirectory = _parseString(json['workingDirectory'])
      ..excludedEnvVariables = _parseStringList(json['excludedEnvVariables'])
      ..excludeEnvVariablesByRegex =
          _parseStringList(json['excludeEnvVariablesByRegex'])
      ..timerJSAction = _parseString(json['timerJSAction'])
      ..timerIntervalSeconds = _parseInt(json['timerIntervalSeconds'], 60)
      ..cleanupOutputsFolder = _parseBool(json['cleanupOutputsFolder'], false)
      ..cliExecutionErrorJSAction =
          _parseString(json['cliExecutionErrorJSAction'])
      ..cliOutputLineJSAction = _parseString(json['cliOutputLineJSAction'])
      ..skipPreJSAction = _parseBool(json['skipPreJSAction'], false)
      ..skipPreCliJSAction = _parseBool(json['skipPreCliJSAction'], false)
      ..skipPostJSAction = _parseBool(json['skipPostJSAction'], false)
      ..includeAttachments =
          _parseAttachmentFlag(json, 'includeAttachments', true)
      ..skipAllAttachments =
          _parseAttachmentFlag(json, 'skipAllAttachments', false)
      ..skipVideoAttachments =
          _parseAttachmentFlag(json, 'skipVideoAttachments', false)
      ..outputType = _parseString(json['outputType'])
      ..envVariables = _parseStringMap(json['envVariables'])
      ..metadata = _parseDynamicMap(json['metadata'])
      ..initiator = _parseString(json['initiator'])
      ..preJSAction = _parseString(json['preJSAction'])
      ..postJSAction = _parseString(json['postJSAction'])
      ..customParams = _parseDynamicMap(json['customParams'])
      ..inputContextConfig = InputContextConfig.fromJson(json);
  }
}

// ----------------------------------------------------------------------
// JSON parsing helpers (top-level, private to this library).
// ----------------------------------------------------------------------

String? _parseString(dynamic value) => value == null ? null : value.toString();

bool _parseBool(dynamic value, bool defaultValue) {
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  return defaultValue;
}

bool _parseAttachmentFlag(
  Map<String, dynamic> json,
  String key,
  bool defaultValue,
) {
  if (json.containsKey(key) && json[key] != null) {
    return _parseBool(json[key], defaultValue);
  }
  final input = json['input'];
  if (input is Map && input.containsKey(key) && input[key] != null) {
    return _parseBool(input[key], defaultValue);
  }
  return defaultValue;
}

int _parseInt(dynamic value, int defaultValue) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return defaultValue;
}

List<String> _parseStringList(dynamic value) {
  if (value is List) {
    return value.whereType<String>().toList(growable: false);
  }
  return const [];
}

Map<String, String>? _parseStringMap(dynamic value) {
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v.toString()));
  }
  return null;
}

Map<String, dynamic>? _parseDynamicMap(dynamic value) {
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}

Map<String, List<String>>? _parsePromptsByTracker(dynamic value) {
  if (value is! Map) return null;
  final result = <String, List<String>>{};
  for (final entry in value.entries) {
    if (entry.value is List) {
      result[entry.key.toString()] =
          (entry.value as List).whereType<String>().toList();
    }
  }
  return result;
}

/// Flattens `cliPrompts` (string array or structured config) to a flat list.
///
/// Each element can be a plain string or an object with `id`, `prompt`/`prompts`,
/// and optional `condition` keys (the `CliPromptsConfig` structured form).
/// Returns `null` when the input is null or empty.
List<String>? _flattenCliPrompts(
  dynamic value, {
  bool Function(String condition)? conditionEvaluator,
}) {
  if (value == null || value is! List) return null;
  final result = <String>[];
  for (final item in value) {
    result.addAll(
      _flattenCliPromptItem(item, conditionEvaluator: conditionEvaluator),
    );
  }
  return result.isEmpty ? null : result;
}

/// Flattens a single `cliPrompts` element (string or section object).
List<String> _flattenCliPromptItem(
  dynamic item, {
  bool Function(String condition)? conditionEvaluator,
}) {
  if (item is String) return [item];
  if (item is! Map) return const [];
  if (!_shouldIncludePromptSection(item, conditionEvaluator)) {
    return const [];
  }
  return _extractSectionStrings(item);
}

bool _shouldIncludePromptSection(
  Map<dynamic, dynamic> item,
  bool Function(String condition)? conditionEvaluator,
) {
  final condition = item['condition'];
  if (condition is! String || conditionEvaluator == null) return true;
  final trimmed = condition.trim();
  return trimmed.isEmpty || conditionEvaluator(trimmed);
}

List<String> _extractSectionStrings(Map<dynamic, dynamic> item) {
  final result = <String>[];
  final singlePrompt = item['prompt'];
  if (singlePrompt is String && singlePrompt.isNotEmpty) {
    result.add(singlePrompt);
  }
  final prompts = item['prompts'];
  if (prompts is List) {
    result.addAll(prompts.whereType<String>());
  }
  return result;
}

/// Parses a JS condition return value (JSON string or decoded object) into a boolean.
bool isCliPromptConditionMet(dynamic rawResult) {
  if (rawResult == null) return false;
  if (rawResult is bool) return rawResult;
  if (rawResult is Map) return _isConditionMetFromMap(rawResult);
  return _isConditionMetFromString(rawResult.toString().trim());
}

bool _isConditionMetFromMap(Map<dynamic, dynamic> map) {
  if (map['uncaughtException'] == true) return false;
  return isCliPromptConditionMet(map['result']);
}

bool _isConditionMetFromString(String str) {
  final lower = str.toLowerCase();
  if (lower == 'true' || str == '"true"') return true;
  if (!str.startsWith('{')) return false;
  final hasTrueResult =
      RegExp(r'"result"\s*:\s*(true|"true")', caseSensitive: false)
          .hasMatch(str);
  final hasException =
      RegExp(r'"uncaughtException"\s*:\s*true', caseSensitive: false)
          .hasMatch(str);
  return hasTrueResult && !hasException;
}
