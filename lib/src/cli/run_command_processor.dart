/// `dmtools run` command argument processing — Dart port of Java
/// `RunCommandProcessor`.
///
/// Resolves the three `run` invocation modes:
/// - `.js` script → JSRunner config.
/// - Known job name (no matching file) → minimal job config.
/// - JSON config file → full resolution (parent chain, encoded override,
///   CLI parameter overrides).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config_merger.dart';
import 'encoding_detector.dart';
import 'job_registry.dart';
import '../config/property_reader.dart';
import '../config/property_reader_getters.dart';
import '../pack/agent_pack_resolver.dart';

const _kParamsCliPrompts = 'params.cliPrompts';

/// Global shell-level verbosity flags ignored during `run` argument extraction.
const _kRunShellFlags = {'--verbose', '--debug', '--quiet'};

/// Processes `dmtools run` command arguments into resolved config JSON.
class RunCommandProcessor {
  /// Creates a run-command processor. [packResolver] is a test seam for the
  /// agent-pack path (dm.ai #579).
  const RunCommandProcessor({AgentPackResolver? packResolver})
      : _packResolver = packResolver;

  final AgentPackResolver? _packResolver;

  /// Processes run command args and returns resolved config JSON.
  ///
  /// [args] layout (first element is `run`):
  /// ```
  /// ["run", filePath, encodedConfig?, --key, value, ...]
  /// ["run", jobName,  --key, value, ...]
  /// ["run", script.js, encodedConfig?]
  /// ```
  ///
  /// Returns the resolved config as a compact JSON string.
  /// Throws [ArgumentError] on invalid arguments or missing files.
  String process(List<String> args) {
    if (args.length < 2) {
      throw ArgumentError(
        'run command requires at least a file path or job name',
      );
    }
    final target = args[1];
    final runArgs = _extractRunArgs(args.sublist(2));

    // dm.ai #579: a versioned agent pack (local .zip or https URL) — resolve to
    // the unpacked, verified cache and run the entry config from there.
    final packResolver = _packResolver ?? AgentPackResolver();
    if (packResolver.isPack(target)) {
      // SOURCE_GITHUB_TOKEN authorizes private GitHub release downloads —
      // the same PropertyReader chain every other integration reads.
      final pack = packResolver.resolve(
        target,
        githubToken: PropertyReader().getGithubToken(),
      );
      return _processConfigFile(
        pack.entryFile.path,
        runArgs,
        packRoot: pack.packRoot,
      );
    }

    if (target.endsWith('.js')) {
      return _processJsFile(target, runArgs);
    }
    if (JobRegistry.isKnownJob(target) && !File(target).existsSync()) {
      return _processJobName(target, runArgs);
    }
    return _processConfigFile(target, runArgs);
  }

  // ------------------------------------------------------------------
  // Argument extraction
  // ------------------------------------------------------------------

  /// Extracts the encoded config (first non-flag arg) and `--key value`
  /// overrides from the tokens after the target.
  _RunArgs _extractRunArgs(List<String> remaining) {
    String? encodedConfig;
    final overrides = <String, String>{};
    var foundEncoded = false;
    var i = 0;
    while (i < remaining.length) {
      final arg = remaining[i];
      if (_kRunShellFlags.contains(arg)) {
        i++;
      } else if (arg.startsWith('--')) {
        final key = arg.substring(2);
        if (i + 1 < remaining.length) {
          overrides[key] = remaining[i + 1];
          i += 2;
        } else {
          i++;
        }
      } else if (!foundEncoded) {
        encodedConfig = arg;
        foundEncoded = true;
        i++;
      } else {
        i++;
      }
    }
    return _RunArgs(encodedConfig, overrides);
  }

  /// Parses a CLI override value into its typed form.
  ///
  /// - Strings starting with `[` → JSON arrays.
  /// - Strings starting with `{` → JSON objects.
  /// - Other strings → left as strings.
  ///
  /// Structured JSON is applied only when the WHOLE trimmed string decodes to
  /// an array or object (parity with Java dm.ai#688). Any decode failure or
  /// trailing text keeps the original string.
  dynamic _parseOverrideValue(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List || decoded is Map) return decoded;
      } on FormatException {
        // Not valid JSON as a whole — keep the raw string.
      }
    }
    return value;
  }

  // ------------------------------------------------------------------
  // Mode A — .js script → JSRunner
  // ------------------------------------------------------------------

  /// Builds a JSRunner config for a `.js` script, applying encoded config and
  /// CLI overrides (the latter land in `jobParams`).
  String _processJsFile(String jsPath, _RunArgs runArgs) {
    var config = <String, dynamic>{
      'name': 'JSRunner',
      'params': <String, dynamic>{
        'jsPath': jsPath,
        'jobParams': <String, dynamic>{},
      },
    };
    config = _applyEncodedConfig(config, runArgs.encodedConfig);
    _injectJobParams(config, runArgs.overrides);
    return jsonEncode(config);
  }

  /// Injects CLI overrides into `params.jobParams` of [config] (mutates in
  /// place).
  void _injectJobParams(
    Map<String, dynamic> config,
    Map<String, String> overrides,
  ) {
    if (overrides.isEmpty) return;
    final params = config['params'] as Map<String, dynamic>;
    final jobParams = Map<String, dynamic>.from(
      params['jobParams'] as Map<String, dynamic>? ?? const {},
    );
    for (final entry in overrides.entries) {
      jobParams[entry.key] = _parseOverrideValue(entry.value);
    }
    params['jobParams'] = jobParams;
  }

  // ------------------------------------------------------------------
  // Mode B — known job name
  // ------------------------------------------------------------------

  /// Builds a minimal config for a known job name, applying encoded config and
  /// CLI overrides into `params`.
  String _processJobName(String jobName, _RunArgs runArgs) {
    var config = <String, dynamic>{
      'name': jobName,
      'params': <String, dynamic>{},
    };
    config = _applyEncodedConfig(config, runArgs.encodedConfig);
    _injectParams(config, runArgs.overrides);
    return jsonEncode(config);
  }

  // ------------------------------------------------------------------
  // Mode C — JSON config file
  // ------------------------------------------------------------------

  /// Loads, resolves and merges a JSON config file.
  ///
  /// When [packRoot] is set (running from an agent pack, dm.ai #579), the
  /// resolved config's repo-relative path references are rewritten to absolute
  /// paths inside the unpacked pack so the agent runs with no repo checkout.
  String _processConfigFile(
    String path,
    _RunArgs runArgs, {
    Directory? packRoot,
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ArgumentError('Config file not found: $path');
    }
    final raw = file.readAsStringSync();
    var config = jsonDecode(raw) as Map<String, dynamic>;
    final resolved = _ParentConfigResolver(packResolver: _packResolver)
        .resolveWithPack(config, file.parent.path);
    final effectivePackRoot = packRoot ?? resolved.packRoot;
    config = _applyEncodedConfig(resolved.config, runArgs.encodedConfig);
    _injectParams(config, runArgs.overrides);
    if (effectivePackRoot != null) {
      AgentPackResolver().rewritePathsToPackRoot(config, effectivePackRoot);
    }
    return jsonEncode(config);
  }

  // ------------------------------------------------------------------
  // Shared helpers
  // ------------------------------------------------------------------

  /// Deep-merges a decoded encoded config onto [config] (no-op when null/empty).
  Map<String, dynamic> _applyEncodedConfig(
    Map<String, dynamic> config,
    String? encodedConfig,
  ) {
    if (encodedConfig == null || encodedConfig.isEmpty) return config;
    final decoded = autoDetectAndDecode(encodedConfig);
    final override = jsonDecode(decoded) as Map<String, dynamic>;
    return deepMerge(config, override);
  }

  /// Injects CLI overrides into `params` of [config] (mutates in place).
  void _injectParams(
    Map<String, dynamic> config,
    Map<String, String> overrides,
  ) {
    if (overrides.isEmpty) return;
    final params = Map<String, dynamic>.from(
      config['params'] as Map<String, dynamic>? ?? const {},
    );
    for (final entry in overrides.entries) {
      params[entry.key] = _parseOverrideValue(entry.value);
    }
    config['params'] = params;
  }
}

/// Internal container for the two pieces extracted from the post-target args.
class _RunArgs {
  /// The optional encoded config (first non-flag token).
  final String? encodedConfig;

  /// `--key value` CLI overrides.
  final Map<String, String> overrides;

  _RunArgs(this.encodedConfig, this.overrides);
}

// ======================================================================
// Parent-config resolution
// ======================================================================

typedef _ResolvedParentConfig = ({
  Map<String, dynamic> config,
  Directory? packRoot,
});

/// Simplified port of Java `ParentConfigResolver`.
///
/// Walks the `"parent"` chain declared in a config, deep-merging each child
/// onto its resolved parent while honouring `"override"` and `"merge"`
/// directives.
class _ParentConfigResolver {
  /// Creates a resolver; [packResolver] is a test seam for pack parents.
  _ParentConfigResolver({AgentPackResolver? packResolver})
      : _packResolver = packResolver ?? AgentPackResolver();

  final AgentPackResolver _packResolver;

  /// Resolves [child] by walking up its parent chain.
  ///
  /// [configDir] is the directory of the file that [child] was loaded from;
  /// parent paths are resolved relative to it.
  Map<String, dynamic> resolve(
    Map<String, dynamic> child,
    String configDir, {
    bool rebaseActions = true,
  }) =>
      resolveWithPack(child, configDir, rebaseActions: rebaseActions).config;

  /// Resolves [child] and returns both the merged config and the nearest
  /// ancestor [packRoot] when inherited from an agent pack.
  _ResolvedParentConfig resolveWithPack(
    Map<String, dynamic> child,
    String configDir, {
    bool rebaseActions = true,
  }) {
    if (rebaseActions) _rebaseActionPaths(child, configDir);
    final parentBlock = child['parent'];
    if (parentBlock is! Map<String, dynamic>) {
      return (config: _stripMeta(child), packRoot: null);
    }
    final path = parentBlock['path'];
    if (path is! String) {
      return (config: _stripMeta(child), packRoot: null);
    }
    final loaded = _loadAndResolve(path, configDir);
    final overridePaths = _readStringList(child, 'override');
    final mergePaths = _readStringList(child, 'merge');
    final strippedChild = _stripMeta(child);
    if (loaded.packRoot != null) {
      // The parent is an agent pack: the child's `pack:` references and
      // repo-relative paths point inside it (zip flow — no agents checkout).
      _rewritePackRefs(strippedChild, loaded.packRoot!);
      _packResolver.rewritePathsToPackRoot(strippedChild, loaded.packRoot!);
    } else if (_containsPackRef(strippedChild)) {
      throw ArgumentError.value(
        path,
        'parent.path',
        'child config uses pack: references but its parent is not an agent pack',
      );
    }
    return (
      config: _mergeWithDirectives(
        loaded.config,
        strippedChild,
        overridePaths,
        mergePaths,
      ),
      packRoot: loaded.packRoot,
    );
  }

  /// Rebases the JS/script action fields of [config] to [configDir] (gh-409).
  ///
  /// A relative action path is resolved against the config file's directory
  /// when that file exists there; otherwise it is left untouched so the
  /// legacy CWD-relative resolution still applies (Java-compatible
  /// fallback). Absolute paths and `pack:` refs are never rewritten.
  void _rebaseActionPaths(Map<String, dynamic> config, String configDir) {
    for (final key in _actionPathKeys) {
      final value = config[key];
      if (value is! String) continue;
      final trimmed = value.trim();
      if (trimmed.isEmpty ||
          p.isAbsolute(trimmed) ||
          trimmed.startsWith(_packScheme)) {
        continue;
      }
      final candidate = p.join(configDir, trimmed);
      if (File(candidate).existsSync()) config[key] = candidate;
    }
  }

  /// Config keys holding a script/action path resolved relative to the
  /// config file (gh-409 AC3).
  static const List<String> _actionPathKeys = [
    'thenAction',
    'preJSAction',
    'postJSAction',
    'preCliJSAction',
  ];

  /// Loads the parent config (filesystem path or agent pack ref) and
  /// recursively resolves it. Returns the resolved config plus the pack
  /// root when the parent came from an agent pack, so the caller can
  /// resolve the child's `pack:` references against it.
  _ResolvedParentConfig _loadAndResolve(
    String parentPath,
    String configDir,
  ) {
    if (_packResolver.isPack(parentPath)) {
      // Pack ref (local .zip / http(s) URL / <agent>@<version|latest>):
      // resolve to the unpacked cache, load the entry config from there,
      // resolve the parent's own chain inside the pack, and rewrite its
      // pack-relative paths to absolute cache paths so they keep working
      // after the merge with a child that may live in another pack or repo.
      final pack = _packResolver.resolve(
        parentPath,
        githubToken: PropertyReader().getGithubToken(),
      );
      final json =
          jsonDecode(pack.entryFile.readAsStringSync()) as Map<String, dynamic>;
      // Pack entries keep their pack-root rewriting (no config-dir rebase).
      final config = resolve(
        json,
        pack.entryFile.parent.path,
        rebaseActions: false,
      );
      _packResolver.rewritePathsToPackRoot(config, pack.packRoot);
      // `pack:` references inside the entry config resolve against this
      // same pack.
      _rewritePackRefs(config, pack.packRoot);
      return (config: config, packRoot: pack.packRoot);
    }
    if (_packResolver.isRegistryRefShaped(parentPath) &&
        !_packResolver.hasRegistry) {
      // `<agent>@<version|latest>` shape with no registry configured: a bare
      // "file not found" here would send every machine leg debugging the
      // wrong layer — say what is actually missing.
      throw ArgumentError.value(
        parentPath,
        'parent.path',
        'is an agent-pack registry ref (<agent>@<version|latest>) but no '
            'pack registry is configured — set the DMTOOLS_PACK_REGISTRY '
            'env var to the release-registry base URL',
      );
    }
    final file = File('$configDir/$parentPath');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return resolveWithPack(json, file.parent.path);
  }

  /// Scheme prefix marking a config string as a reference into the resolved
  /// parent agent pack (`pack:instructions/foo.md`). Only meaningful when
  /// the config's parent is a pack.
  static const String _packScheme = 'pack:';

  /// Rewrites every `pack:` string under [node] to an absolute path inside
  /// [packRoot]; throws [AgentPackException] on root escapes or missing
  /// files. Non-string leaves and scheme-less strings pass through.
  void _rewritePackRefs(Object? node, Directory packRoot) {
    if (node is Map<String, dynamic>) {
      for (final key in node.keys.toList()) {
        _rewriteValue(node[key], (resolved) => node[key] = resolved, packRoot);
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        final index = i; // per-iteration capture for the assign closure
        _rewriteValue(
          node[index],
          (resolved) => node[index] = resolved,
          packRoot,
        );
      }
    }
  }

  /// Resolves one node value: `pack:` strings are rewritten via [assign],
  /// nested maps/lists recursed into; everything else passes through.
  void _rewriteValue(
    Object? value,
    void Function(String resolved) assign,
    Directory packRoot,
  ) {
    final resolved = value is String ? _resolvePackRef(value, packRoot) : null;
    if (resolved != null) {
      assign(resolved);
    } else if (value is Map || value is List) {
      _rewritePackRefs(value, packRoot);
    }
  }

  /// True when any string under [node] carries the `pack:` scheme.
  bool _containsPackRef(Object? node) {
    if (node is String) return node.trim().startsWith(_packScheme);
    if (node is Map<String, dynamic>) {
      return node.values.any(_containsPackRef);
    }
    if (node is List) return node.any(_containsPackRef);
    return false;
  }

  /// Maps a `pack:`-prefixed string to an existing absolute path inside
  /// [packRoot]; returns `null` for strings without the scheme.
  String? _resolvePackRef(String value, Directory packRoot) {
    var ref = value.trim();
    if (!ref.startsWith(_packScheme)) return null;
    ref = ref.substring(_packScheme.length);
    while (ref.startsWith('/')) {
      ref = ref.substring(1);
    }
    final candidate = File(p.normalize(p.join(packRoot.path, ref)));
    if (!p.isWithin(packRoot.path, candidate.path) || !candidate.existsSync()) {
      throw AgentPackException(
        "pack: reference '$value' not found in pack '${packRoot.path}'",
      );
    }
    return candidate.path;
  }

  /// Removes `parent`, `override` and `merge` meta keys, returning a copy.
  Map<String, dynamic> _stripMeta(Map<String, dynamic> config) {
    final result = Map<String, dynamic>.from(config);
    result
      ..remove('parent')
      ..remove('override')
      ..remove('merge');
    return result;
  }

  /// Deep-merges then applies explicit override and merge directives.
  Map<String, dynamic> _mergeWithDirectives(
    Map<String, dynamic> parent,
    Map<String, dynamic> child,
    List<String> overridePaths,
    List<String> mergePaths,
  ) {
    var result = deepMerge(parent, child);
    for (final path in overridePaths) {
      final childValue = _getByPath(child, path);
      if (childValue != null) {
        _setByPath(result, path, childValue);
      }
    }
    for (final path in mergePaths) {
      _applyMergeDirective(result, parent, child, path);
    }
    if (!overridePaths.contains(_kParamsCliPrompts) &&
        !mergePaths.contains(_kParamsCliPrompts)) {
      _applyStructuredCliPromptsMerge(result, parent, child);
    }
    return result;
  }

  /// Concatenates parent + child arrays at [path] inside [result].
  /// For `params.cliPrompts`, if either side contains section objects, merges
  /// sections by `id` (Java `CliPromptsConfig.merge` parity).
  void _applyMergeDirective(
    Map<String, dynamic> result,
    Map<String, dynamic> parent,
    Map<String, dynamic> child,
    String path,
  ) {
    final parentValue = _getByPath(parent, path);
    final childValue = _getByPath(child, path);
    if (parentValue is List && childValue is List) {
      if (path == _kParamsCliPrompts &&
          (_containsStructuredPrompts(parentValue) ||
              _containsStructuredPrompts(childValue))) {
        _setByPath(
          result,
          path,
          _mergeStructuredCliPrompts(parentValue, childValue),
        );
      } else {
        _setByPath(result, path, [...parentValue, ...childValue]);
      }
    }
  }

  /// Merges structured `params.cliPrompts` by section `id` when either parent
  /// or child uses section objects (Java `ParentConfigResolver` parity).
  void _applyStructuredCliPromptsMerge(
    Map<String, dynamic> result,
    Map<String, dynamic> parent,
    Map<String, dynamic> child,
  ) {
    final parentValue = _getByPath(parent, _kParamsCliPrompts);
    final childValue = _getByPath(child, _kParamsCliPrompts);
    if (parentValue is! List || childValue is! List) return;
    if (_containsStructuredPrompts(parentValue) ||
        _containsStructuredPrompts(childValue)) {
      _setByPath(
        result,
        _kParamsCliPrompts,
        _mergeStructuredCliPrompts(parentValue, childValue),
      );
    }
  }

  bool _containsStructuredPrompts(List<dynamic> list) =>
      list.any((item) => item is Map);

  List<dynamic> _mergeStructuredCliPrompts(
    List<dynamic> baseList,
    List<dynamic> overrideList,
  ) =>
      _mergeCliPromptSections(baseList, overrideList);

  /// Reads a top-level string-list key from [config] (empty when absent).
  /// Reads a top-level string-list key from [config] (empty when absent).
  List<String> _readStringList(Map<String, dynamic> config, String key) {
    final value = config[key];
    if (value is List) {
      return value.whereType<String>().toList(growable: false);
    }
    return const [];
  }

  /// Gets the value at a dot-separated [path] within [map], or `null`.
  dynamic _getByPath(Map<String, dynamic> map, String path) {
    final parts = path.split('.');
    dynamic current = map;
    for (final part in parts) {
      if (current is! Map<String, dynamic>) return null;
      current = current[part];
    }
    return current;
  }

  /// Sets [value] at a dot-separated [path] within [map], creating
  /// intermediate maps as needed (mutates [map]).
  void _setByPath(Map<String, dynamic> map, String path, dynamic value) {
    final parts = path.split('.');
    var current = map;
    for (var i = 0; i < parts.length - 1; i++) {
      final part = parts[i];
      current[part] ??= <String, dynamic>{};
      current = current[part] as Map<String, dynamic>;
    }
    current[parts.last] = value;
  }
}

List<dynamic> _mergeCliPromptSections(
  List<dynamic> baseList,
  List<dynamic> overrideList,
) {
  final merged = <dynamic>[];
  for (final baseItem in baseList) {
    if (baseItem is! Map) {
      merged.add(baseItem);
      continue;
    }
    final overrideMatch = _findSectionById(
      overrideList,
      baseItem['id']?.toString(),
    );
    merged.add(
      overrideMatch == null
          ? baseItem
          : _mergeSectionMaps(baseItem, overrideMatch),
    );
  }
  for (final overrideItem in overrideList) {
    if (overrideItem is! Map ||
        _findSectionById(baseList, overrideItem['id']?.toString()) == null) {
      merged.add(overrideItem);
    }
  }
  return merged;
}

Map<dynamic, dynamic>? _findSectionById(List<dynamic> list, String? id) {
  if (id == null || id.isEmpty) return null;
  for (final item in list) {
    if (item is Map && item['id']?.toString() == id) return item;
  }
  return null;
}

Map<String, dynamic> _mergeSectionMaps(
  Map<dynamic, dynamic> base,
  Map<dynamic, dynamic> over,
) {
  final strategy =
      (over['mergeStrategy']?.toString() ?? 'append').toLowerCase();
  final out = <String, dynamic>{
    'id': base['id'].toString(),
    'prompts': _combineSectionPrompts(
      _extractSectionPrompts(base),
      _extractSectionPrompts(over),
      strategy,
    ),
  };
  _copyOptionalSectionMetadata(base, over, out);
  return out;
}

List<String> _combineSectionPrompts(
  List<String> basePrompts,
  List<String> overPrompts,
  String strategy,
) {
  if (strategy == 'prepend') return [...overPrompts, ...basePrompts];
  if (strategy == 'replace') return [...overPrompts];
  return [...basePrompts, ...overPrompts];
}

void _copyOptionalSectionMetadata(
  Map<dynamic, dynamic> base,
  Map<dynamic, dynamic> over,
  Map<String, dynamic> out,
) {
  final baseStrategy = base['mergeStrategy']?.toString();
  if (baseStrategy != null &&
      baseStrategy.isNotEmpty &&
      baseStrategy != 'append') {
    out['mergeStrategy'] = baseStrategy;
  }
  final overCond = over['condition']?.toString().trim();
  final baseCond = base['condition']?.toString().trim();
  final cond = (overCond != null && overCond.isNotEmpty) ? overCond : baseCond;
  if (cond != null && cond.isNotEmpty) {
    out['condition'] = cond;
  }
}

List<String> _extractSectionPrompts(Map<dynamic, dynamic> section) {
  final out = <String>[];
  final single = section['prompt'];
  if (single is String && single.isNotEmpty) out.add(single);
  final list = section['prompts'];
  if (list is List) out.addAll(list.whereType<String>());
  return out;
}
