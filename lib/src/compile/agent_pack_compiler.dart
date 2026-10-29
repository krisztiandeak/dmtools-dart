/// Builds a versioned, self-contained agent pack (`<agent>-<version>.zip` +
/// `manifest.json` + `.sha256`) from an agent entry config in a dmtools-agents
/// checkout. Dart port of the Java `AgentPackCompiler` (dm.ai #595); the pack
/// format is the shared contract consumed by the agent-pack runtime (#579).
///
/// The closure is computed, never hard-coded: the entry config is parsed for
/// referenced paths (`jsPath`, `preJSAction`, `preCliJSAction`, `postJSAction`,
/// `timerJSAction`, `preprocessJSAction`, `cliPrompts`, `cliCommands`,
/// `metadata.descriptionPath`, `parent.path` chains), each referenced JS file is
/// transitively scanned for `require(...)`/`loadModule(...)`, and the whole
/// `scripts/` subtree is embedded when any script is referenced.
///
/// Path duality: `agents/js/x.js` and `js/x.js` both normalize to the
/// pack-relative `js/x.js`. The zip is deterministic (sorted entries, fixed
/// timestamps, `0755` on `*.sh`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../pack/pack_provenance.dart';
import 'js_scrubber.dart';

/// The result of a compile: the produced artifacts.
class PackResult {
  /// Creates a result with the produced artifact paths.
  const PackResult({
    required this.zipFile,
    required this.manifestFile,
    required this.shaFile,
    required this.fileCount,
  });

  /// The produced `<agent>-<version>.zip`.
  final File zipFile;

  /// The emitted `manifest.json`.
  final File manifestFile;

  /// The `<agent>-<version>.zip.sha256` sidecar.
  final File shaFile;

  /// Number of files embedded in the pack.
  final int fileCount;
}

/// Agent pack compiler — see the library doc for the closure rules.
class AgentPackCompiler {
  /// Creates a compiler rooted at the agents checkout (contains `js/`,
  /// `instructions/`, etc.).
  AgentPackCompiler(this.agentRoot)
      : _rootPath = p.normalize(Directory(agentRoot).absolute.path);

  /// The agents checkout root path as given.
  final String agentRoot;

  final String _rootPath;

  /// Fixed zip entry timestamp for reproducible builds (the zip epoch).
  static final DateTime _fixedTime = DateTime.utc(1980);

  /// JSON keys (at any depth) holding a single path.
  static const _singlePathKeys = [
    'jsPath',
    'preJSAction',
    'preCliJSAction',
    'postJSAction',
    'timerJSAction',
    'preprocessJSAction',
    'preAction',
    'postAction',
    'thenAction',
  ];

  /// Matches `require('./x.js')` / `loadModule('./x.js')`.
  static final _jsModuleRef =
      RegExp("(?:require|loadModule)\\(\\s*['\"]([^'\"]+)['\"]\\s*\\)");

  /// A string that references a repo file (has an extension and a separator).
  static final _pathLike =
      RegExp(r'^[./]*[\w./-]+\.(js|json|md|sh|py|txt|yaml|yml|properties)$');

  /// Compiles the pack for [entryJson].
  ///
  /// [extraDirs] lists repo-relative directories to embed WHOLE (every file
  /// under them), on top of the computed closure — the zip-flow contract
  /// for files only the consuming child configs reference (e.g. the shared
  /// `instructions/`/`prompts/` subtrees of a dmtools-agents pack that
  /// runner children reach via `pack:` refs). A missing directory throws
  /// [AgentPackException].
  ///
  /// Throws [AgentPackException] on a missing referenced file (with the exact
  /// path) or on any I/O failure; nothing is written on failure.
  PackResult compile(
    File entryJson,
    String version,
    String sourceCommit,
    Directory outDir, {
    List<String> extraDirs = const [],
  }) {
    final agentName = _stripJsonExtension(_basename(entryJson.path));

    // pack-relative path -> absolute source file, sorted for determinism.
    final closure = <String, File>{};
    final visitedConfigs = <String>{};
    final visitedJs = <String>{};

    _collectConfig(entryJson.absolute, closure, visitedConfigs, visitedJs);

    for (final dir in extraDirs) {
      _includeSubtree(closure, dir);
    }

    _includeIfExists(closure, 'AGENTS.md');
    _includeIfExists(closure, 'LICENSE');
    closure[_basename(entryJson.path)] = entryJson.absolute;

    if (closure.isEmpty) {
      throw AgentPackException(
          'Empty closure for ${_basename(entryJson.path)} — nothing to pack');
    }

    final manifest = _buildManifest(
        agentName, version, sourceCommit, _basename(entryJson.path), closure);

    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final base = '$agentName-$version';
    final zipFile = File('${outDir.path}/$base.zip');
    final manifestFile = File('${outDir.path}/manifest.json');
    final shaFile = File('${outDir.path}/$base.zip.sha256');

    _writeDeterministicZip(closure, manifest, zipFile);
    manifestFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(manifest));
    shaFile.writeAsStringSync(
        '${_sha256Hex(zipFile.readAsBytesSync())}  ${_basename(zipFile.path)}\n');

    return PackResult(
      zipFile: zipFile,
      manifestFile: manifestFile,
      shaFile: shaFile,
      fileCount: closure.length,
    );
  }

  // ------------------------------------------------------------------
  // Closure walking
  // ------------------------------------------------------------------

  /// Recursively collects a config and its `parent.path` chain.
  void _collectConfig(File configFile, Map<String, File> closure,
      Set<String> visitedConfigs, Set<String> visitedJs) {
    final normalized = configFile.absolute.path;
    if (!visitedConfigs.add(normalized)) return; // cycle safety
    if (!configFile.existsSync()) {
      throw AgentPackException('Config not found: $normalized');
    }
    final config = _parseJson(configFile, normalized);

    _collectPathsFromJson(config, closure, visitedJs);

    final parent = config['parent'];
    if (parent is Map<String, dynamic>) {
      final parentPath = parent['path'];
      if (parentPath is String && parentPath.isNotEmpty) {
        final resolved = _resolveReference(parentPath);
        if (resolved == null) {
          throw AgentPackException(
              'parent.path not found: $parentPath (referenced from $normalized)');
        }
        closure.putIfAbsent(_packRelative(resolved), () => resolved);
        _collectConfig(resolved, closure, visitedConfigs, visitedJs);
      }
    }
  }

  Map<String, dynamic> _parseJson(File file, String label) {
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (e) {
      throw AgentPackException('Invalid JSON in $label: ${e.message}');
    }
    throw AgentPackException('Config is not a JSON object: $label');
  }

  /// Walks the config JSON, collecting referenced files from known fields.
  void _collectPathsFromJson(Map<String, dynamic> config,
      Map<String, File> closure, Set<String> visitedJs) {
    _collectSinglePathKeys(config, closure, visitedJs);
    for (final item in _findList(config, 'cliPrompts')) {
      _collectCliPromptItem(
        item,
        (v) => _maybeAddPathReference(v, closure, visitedJs),
        (v) => _addPathReference(v, closure, visitedJs),
      );
    }
    _collectPromptsByTracker(config, closure, visitedJs);
    _collectCliCommands(config, closure, visitedJs);
  }

  void _collectPromptsByTracker(Map<String, dynamic> config,
      Map<String, File> closure, Set<String> visitedJs) {
    final byTracker = _deepFindMap(config, 'cliPromptsByTracker');
    if (byTracker == null) return;
    for (final list in byTracker.values.whereType<List>()) {
      for (final item in list) {
        _collectCliPromptItem(
          item,
          (v) => _maybeAddPathReference(v, closure, visitedJs),
          (v) => _addPathReference(v, closure, visitedJs),
        );
      }
    }
  }

  /// Collects `cliCommands` paths; any `scripts/**` reference embeds the whole
  /// subtree (scripts self-locate via SCRIPT_DIR).
  void _collectCliCommands(Map<String, dynamic> config,
      Map<String, File> closure, Set<String> visitedJs) {
    var referencesScripts = false;
    for (final item in _findList(config, 'cliCommands')) {
      if (item is String) {
        final normalized = _normalizeReference(item);
        if (normalized != null && normalized.startsWith('scripts/')) {
          referencesScripts = true;
        }
        _maybeAddCommandPath(item, closure, visitedJs);
      }
    }
    if (referencesScripts) _includeScriptsSubtree(closure);
  }

  /// Adds the file for each known single-path key found in the object tree.
  void _collectSinglePathKeys(Map<String, dynamic> obj,
      Map<String, File> closure, Set<String> visitedJs) {
    for (final key in _singlePathKeys) {
      final value = _deepFindString(obj, key);
      if (value != null) _addPathReference(value, closure, visitedJs);
    }
    final metadata = _deepFindMap(obj, 'metadata');
    final descriptionPath = metadata?['descriptionPath'];
    if (descriptionPath is String && descriptionPath.isNotEmpty) {
      _addPathReference(descriptionPath, closure, visitedJs);
    }
  }

  /// Adds a cliPrompts/cliCommands item only when it looks like a file path.
  void _maybeAddPathReference(
      String value, Map<String, File> closure, Set<String> visitedJs) {
    final trimmed = value.trim();
    if (_pathLike.hasMatch(trimmed))
      _addPathReference(trimmed, closure, visitedJs);
  }

  /// Extracts a repo path from a shell command token (`./agents/scripts/x.sh`).
  void _maybeAddCommandPath(
      String command, Map<String, File> closure, Set<String> visitedJs) {
    for (final token in command.split(RegExp(r'\s+'))) {
      final cleaned = token.replaceAll(RegExp("^['\"]+|['\"]+\$"), '');
      if (_pathLike.hasMatch(cleaned)) {
        _addPathReference(cleaned, closure, visitedJs);
      }
    }
  }

  /// Records [rawReference] in the closure under its normalized pack-relative
  /// path; JS files are transitively scanned.
  void _addPathReference(
      String rawReference, Map<String, File> closure, Set<String> visitedJs) {
    final packRelative = _normalizeReference(rawReference);
    if (packRelative == null) return; // URL / classpath: / literal
    final source = File('${_rootPath}/$packRelative');
    final resolved = source.absolute;
    if (!_isWithinRoot(resolved.path)) {
      throw AgentPackException('Reference escapes agent root: $rawReference');
    }
    if (!resolved.existsSync()) {
      throw AgentPackException(
          'Referenced file missing: $rawReference (resolved to ${resolved.path})');
    }
    closure.putIfAbsent(packRelative, () => resolved);
    if (packRelative.endsWith('.js')) {
      _scanJsTransitive(resolved, closure, visitedJs);
    }
  }

  /// Transitively scans a JS file for `require(...)`/`loadModule(...)`.
  void _scanJsTransitive(
      File jsFile, Map<String, File> closure, Set<String> visitedJs) {
    final normalized = jsFile.absolute.path;
    if (!visitedJs.add(normalized)) return; // cycle safety
    final content = jsFile.readAsStringSync();
    final parentDir = File(normalized).parent.path;
    // The scrub is LENGTH-PRESERVING: match offsets in the scrubbed text
    // are valid against the original, so the masked-out reference string
    // is recovered from the original at the same offset.
    for (final match in _jsModuleRef.allMatches(scrubForScan(content))) {
      final raw = content.substring(match.start, match.end);
      final refMatch = _jsModuleRef.firstMatch(raw);
      if (refMatch == null) continue;
      _resolveJsModule(
          refMatch.group(1)!, parentDir, normalized, closure, visitedJs);
    }
  }

  /// Length-preserving scrub for the closure scan: blanks the CONTENTS of
  /// comments, string/template literals, and regex literals while keeping
  /// every byte count (structure chars — quotes, newlines — stay), so
  /// `require('./x.js')` survives as `require('       ')` at identical
  /// offsets and real code is distinguishable from embedded worker-source
  /// strings.
  ///
  /// Regex-literal aware (gh-371): JS decides regex-vs-division from
  /// expression position, so this lexer does too — a `/` in expression
  /// position (after `(`, `,`, `=`, operators, keywords like `return`)
  /// opens a regex literal consumed escape-aware to its closing unescaped
  /// `/` (a `/` inside a `[...]` class never terminates). Without this, a
  /// regex like `/[<>\`\|&;$\r\n]/g` (live: dmtools-agents
  /// js/common/pullRequest.js:48) made the old masker open a phantom
  /// template literal that swallowed every `require(...)` for the next
  /// ~150 lines — pr_review packs shipped without js/common/mergeState.js
  /// and every fa review leg requiring it went red.
  ///
  /// Template interpolations nest properly: `${` re-enters code state and
  /// the matching `}` (brace-balanced) returns to the template, so nested
  /// quotes/backticks inside `${...}` cannot desync the scan either.
  ///
  /// Belt and suspenders: in code state a quote preceded by an odd
  /// backslash run is an escaped character, never a literal opener
  /// (defensive for `\``-style escapes the regex consumer might miss).
  /// Punctuation after which a `/` opens a regex (expression position).
  static String scrubForScan(String src) => scrubJsForScan(src);

  /// Resolves one relative JS module reference and recurses into it.
  void _resolveJsModule(String ref, String parentDir, String fromFile,
      Map<String, File> closure, Set<String> visitedJs) {
    if (!ref.startsWith('./') && !ref.startsWith('../')) return;
    final refWithExt = ref.endsWith('.js') ? ref : '$ref.js';
    final normalizedResolved =
        _normalizePath(p.normalize(p.join(parentDir, refWithExt)));
    if (!_isWithinRoot(normalizedResolved)) return;
    final refFile = File(normalizedResolved);
    if (!refFile.existsSync()) {
      throw AgentPackException(
          'JS module not found: $ref (required from $fromFile)');
    }
    final packRelative = _packRelative(refFile);
    if (closure.containsKey(packRelative)) return;
    closure[packRelative] = refFile;
    _scanJsTransitive(refFile, closure, visitedJs);
  }

  /// Embeds the whole `scripts/` subtree (scripts self-locate via SCRIPT_DIR).
  void _includeScriptsSubtree(Map<String, File> closure) {
    final scriptsDir = Directory('${_rootPath}/scripts');
    if (!scriptsDir.existsSync()) return;
    for (final entity
        in scriptsDir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        closure[_packRelative(entity.absolute)] = entity.absolute;
      }
    }
  }

  /// Adds a top-level file (AGENTS.md / LICENSE) when it exists.
  void _includeIfExists(Map<String, File> closure, String name) {
    final file = File('${_rootPath}/$name');
    if (file.existsSync()) closure[name] = file;
  }

  /// Embeds every file under the repo-relative [dir] into the closure
  /// (pack-relative paths keyed under `dir/…`); symlinks are skipped.
  /// A leading `agents/` is stripped per the path duality. Throws
  /// [AgentPackException] when the directory is missing or escapes the
  /// agents root.
  void _includeSubtree(Map<String, File> closure, String dir) {
    var normalized = p.normalize(dir).replaceAll('\\', '/');
    while (normalized.startsWith('agents/')) {
      normalized = normalized.substring('agents/'.length);
    }
    final rootDir = Directory(p.join(_rootPath, normalized));
    final rootPath = p.normalize(rootDir.absolute.path);
    if (!p.isWithin(_rootPath, rootPath) || rootPath == _rootPath) {
      throw AgentPackException(
          '--include directory escapes the agents root: $dir '
          '(resolved to $normalized, root $_rootPath)');
    }
    if (!rootDir.existsSync()) {
      throw AgentPackException(
          '--include directory not found: $normalized (under $_rootPath)');
    }
    for (final entity
        in rootDir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      closure[_packRelative(entity.absolute)] = entity.absolute;
    }
  }

  // ------------------------------------------------------------------
  // Path normalization (agents/js/x.js -> js/x.js)
  // ------------------------------------------------------------------

  /// Normalizes a reference to its pack-relative path, or returns `null` for a
  /// non-repo-file reference (URL, `classpath:`, or a bare literal).
  String? _normalizeReference(String raw) {
    final ref = raw.trim();
    if (ref.isEmpty ||
        ref.startsWith('http://') ||
        ref.startsWith('https://') ||
        ref.startsWith('classpath:')) {
      return null;
    }
    return normalizePackReferencePath(ref, rootPath: _rootPath);
  }

  /// Resolves a reference to a source file, or `null` when absent/not a file.
  File? _resolveReference(String raw) {
    final packRelative = _normalizeReference(raw);
    if (packRelative == null) return null;
    final resolved = File('${_rootPath}/$packRelative').absolute;
    if (!_isWithinRoot(resolved.path) || !resolved.existsSync()) return null;
    return resolved;
  }

  bool _isWithinRoot(String path) =>
      _normalizePath(path) == _rootPath ||
      _normalizePath(path).startsWith('$_rootPath/');

  String _packRelative(File file) =>
      p.relative(_normalizePath(file.path), from: _rootPath);

  String _normalizePath(String path) => p.normalize(path).replaceAll('\\', '/');

  // ------------------------------------------------------------------
  // Manifest + deterministic zip
  // ------------------------------------------------------------------

  Map<String, dynamic> _buildManifest(String agentName, String version,
      String sourceCommit, String defaultEntry, Map<String, File> closure) {
    final files = <Map<String, dynamic>>[];
    final sortedKeys = closure.keys.toList()..sort();
    for (final path in sortedKeys) {
      final file = closure[path]!;
      files.add({
        'path': path,
        'sha256': _sha256Hex(file.readAsBytesSync()),
        'mode': path.endsWith('.sh') ? '0755' : '0644',
      });
    }
    return {
      'agent': agentName,
      'version': version,
      'sourceCommit': sourceCommit,
      'defaultEntry': defaultEntry,
      'minDmtoolsVersion': 'unknown',
      'files': files,
    };
  }

  void _writeDeterministicZip(
      Map<String, File> closure, Map<String, dynamic> manifest, File zipFile) {
    final archive = Archive();
    final manifestBytes =
        utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest));
    _addEntry(archive, 'manifest.json', manifestBytes, 0644);

    final sortedKeys = closure.keys.toList()..sort();
    for (final path in sortedKeys) {
      final bytes = closure[path]!.readAsBytesSync();
      final mode = path.endsWith('.sh') ? 0755 : 0644;
      _addEntry(archive, path, bytes, mode);
    }

    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw const AgentPackException('Failed to encode pack zip');
    }
    zipFile.writeAsBytesSync(encoded);
  }

  void _addEntry(Archive archive, String path, List<int> bytes, int mode) {
    final entry = ArchiveFile(path, bytes.length, bytes)
      ..lastModTime = _fixedTime.millisecondsSinceEpoch ~/ 1000
      ..mode = mode;
    archive.addFile(entry);
  }

  // ------------------------------------------------------------------
  // Small utilities
  // ------------------------------------------------------------------

  /// Finds a list by key, looking under `params` when not at top level.
  List<dynamic> _findList(Map<String, dynamic> config, String key) {
    final direct = config[key];
    if (direct is List) return direct;
    final params = config['params'];
    if (params is Map<String, dynamic> && params[key] is List) {
      return params[key] as List;
    }
    return const [];
  }

  /// Depth-first search for a string value by key anywhere in the tree.
  String? _deepFindString(Map<String, dynamic> obj, String key) {
    final direct = obj[key];
    if (direct is String) return direct;
    for (final child in obj.values) {
      if (child is Map<String, dynamic>) {
        final found = _deepFindString(child, key);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// Depth-first search for a nested map by key.
  Map<String, dynamic>? _deepFindMap(Map<String, dynamic> obj, String key) {
    final direct = obj[key];
    if (direct is Map<String, dynamic>) return direct;
    for (final child in obj.values) {
      if (child is Map<String, dynamic>) {
        final found = _deepFindMap(child, key);
        if (found != null) return found;
      }
    }
    return null;
  }

  String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  String _basename(String path) => path.replaceAll('\\', '/').split('/').last;

  String _stripJsonExtension(String fileName) => fileName.endsWith('.json')
      ? fileName.substring(0, fileName.length - '.json'.length)
      : fileName;

  /// Strips JS line (`//`) and block (`/* ... */`) comments so the scanner does
  /// not match `require(...)` inside documentation; string literals are kept.
  static String stripJsComments(String src) => _CommentStripper.strip(src);
}

/// Thrown when the pack build fails (missing reference, invalid JSON, ...).
class AgentPackException implements Exception {
  /// Creates an exception with [message].
  const AgentPackException(this.message);

  /// The failure description.
  final String message;

  @override
  String toString() => 'AgentPackException: $message';
}

/// State-machine JS comment stripper preserving string literals.
///
/// Implemented as a tiny per-state machine: each scanner state owns a handler,
/// keeping every method well under the complexity/nesting gates.
class _CommentStripper {
  _CommentStripper(this._src);

  final String _src;
  final StringBuffer _out = StringBuffer();
  int _i = 0;
  _State _state = _State.code;
  String _quote = '';

  static String strip(String src) => _CommentStripper(src)._run();

  String _run() {
    while (_i < _src.length) {
      switch (_state) {
        case _State.code:
          _scanCode();
        case _State.lineComment:
          _scanLineComment();
        case _State.blockComment:
          _scanBlockComment();
        case _State.string:
          _scanString();
      }
      _i++;
    }
    return _out.toString();
  }

  String get _c => _src[_i];

  String get _next => _i + 1 < _src.length ? _src[_i + 1] : '';

  void _scanCode() {
    if (_c == '/' && _next == '/') {
      _state = _State.lineComment;
    } else if (_c == '/' && _next == '*') {
      _state = _State.blockComment;
      _i++; // consume the '*'
    } else {
      if (_isQuote(_c)) {
        _state = _State.string;
        _quote = _c;
      }
      _out.write(_c);
    }
  }

  void _scanLineComment() {
    if (_c == '\n') {
      _state = _State.code;
      _out.write(_c);
    }
  }

  void _scanBlockComment() {
    if (_c == '*' && _next == '/') {
      _state = _State.code;
      _i++; // consume the '/'
    }
  }

  void _scanString() {
    _out.write(_c);
    if (_c == '\\' && _i + 1 < _src.length) {
      _out.write(_src[++_i]); // keep the escaped char verbatim
    } else if (_c == _quote) {
      _state = _State.code;
      _quote = '';
    }
  }

  bool _isQuote(String c) => c == "'" || c == '"' || c == '`';
}

enum _State { code, lineComment, blockComment, string }

void _collectCliPromptItem(
  Object? item,
  void Function(String) onPrompt,
  void Function(String) onCondition,
) {
  if (item is String) {
    onPrompt(item);
    return;
  }
  if (item is! Map) return;
  final single = item['prompt'];
  if (single is String && single.isNotEmpty) onPrompt(single);
  final prompts = item['prompts'];
  if (prompts is List) prompts.whereType<String>().forEach(onPrompt);
  final condition = item['condition'];
  if (condition is String && condition.isNotEmpty) onCondition(condition);
}
