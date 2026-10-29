/// Property resolution engine for DMTools — Dart port of Java `PropertyReader`.
///
/// Resolution chain (mirrors `PropertyReader.getValue`):
/// 1. Static overrides — equivalent of Java's `ThreadLocal` overrides,
///    set by `setOverrides` before job execution. Accepted whenever the key
///    is present, even with an empty value.
/// 2. `config.properties` — `<projectRoot>/src/main/resources/config.properties`
///    from disk, else the [PropertyReader.setConfigFile] resource. Accepted
///    only for non-empty values.
/// 3. `dmtools.env` file — loaded from the project root first, then the
///    working directory (Java `loadEnvFileProperties`). Accepted only for
///    non-empty values; empty entries fall through.
/// 4. OS environment variables — `Platform.environment`, returned as-is.
/// 5. Method-level default (if provided).
library;

import 'dart:async';
import 'dart:io';

import 'env_file_parser.dart';

/// Core property reader with resolution chain and override management.
///
/// Integration-specific getters live in the `PropertyReaderGetters` extension.
class PropertyReader {
  /// Project-root marker files (Java `findProjectRoot` walks up looking for
  /// Gradle settings files — PropertyReader.java lines 92-93). NOT
  /// pubspec.yaml: the Dart port mirrors the Java marker contract.
  static const _gradleMarkers = <String>[
    'settings.gradle',
    'settings.gradle.kts'
  ];

  /// Resource path consulted by the config.properties fallback tier (Java
  /// line 21: `PATH_TO_CONFIG_FILE = "/config.properties"`). Only the
  /// fallback lookup is affected — never the on-disk `<root>/src/main/
  /// resources/config.properties` tier.
  static String _pathToConfigFile = '/config.properties';

  /// Points the config.properties fallback tier at [resourcePath].
  ///
  /// Java resolves this path against the classpath; a pure Dart VM has no
  /// classpath, so the recorded path is resolved against the filesystem
  /// instead (absolute as-is, relative to the reader's [basePath] / CWD)
  /// and only adopted when it names an existing regular file — an absent
  /// resource yields nothing, exactly like a classpath miss.
  static void setConfigFile(String resourcePath) {
    _pathToConfigFile = resourcePath;
  }

  // --- Static overrides (Java ThreadLocal equivalent) ---

  /// Zone key carrying the per-job override map inside [runWithOverrides].
  ///
  /// Dart's [Zone] is the analog of Java's `ThreadLocal`: values flow
  /// through `await` boundaries and stay isolated between concurrently
  /// running jobs in the same isolate.
  static const _overridesZoneKey = #dmtoolsPropertyOverrides;

  /// Root-level overrides, used outside a [runWithOverrides] scope.
  ///
  /// Safe for the single-job CLI flow; concurrent jobs must use
  /// [runWithOverrides] so one job's [clearOverrides] cannot wipe another's
  /// overrides mid-flight.
  static Map<String, String>? _overrides;

  /// Sets zone-static overrides for the current isolate.
  ///
  /// Called by `JobRunner` before job execution, built from
  /// `TrackerParams.getEnvVariables()`.
  static final _envVarTokenPattern = RegExp(
    r'\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))',
  );

  /// Collected unresolved-variable warnings from the most recent
  /// [resolveEnvVariables] call (for testing).
  static final List<String> lastUnresolvedWarnings = [];

  /// Interpolates `$VAR` and `${VAR}` tokens in [overrides] values.
  ///
  /// Resolution order for each referenced variable name:
  /// 1. [extraEnv] when provided and non-empty (e.g. `workDir/dmtools.env`).
  /// 2. Another entry in [overrides] whose value does not start with `$`.
  /// 3. Underlying [PropertyReader] lookup (`config.properties`, `dmtools.env`,
  ///    and OS/test environment) bypassing active overrides.
  /// 4. Unchanged `$VAR` / `${VAR}` token when unset (`null`), logging a
  ///    warning to `stderr` and recording it in [lastUnresolvedWarnings].
  static Map<String, String> resolveEnvVariables(
    Map<String, String> overrides, {
    Map<String, String>? extraEnv,
    String? basePath,
  }) {
    lastUnresolvedWarnings.clear();
    if (overrides.isEmpty) return const <String, String>{};
    PropertyReader? reader;
    return {
      for (final entry in overrides.entries)
        entry.key: _interpolateValue(
          entry.key,
          entry.value,
          overrides,
          extraEnv,
          () => reader ??= PropertyReader(basePath: basePath),
        ),
    };
  }

  static String _interpolateValue(
    String currentKey,
    String rawValue,
    Map<String, String> overrides,
    Map<String, String>? extraEnv,
    PropertyReader Function() readerProvider,
  ) {
    if (!rawValue.contains(r'$')) return rawValue;
    return rawValue.replaceAllMapped(_envVarTokenPattern, (match) {
      final varName = (match.group(1) ?? match.group(2))!;
      final resolved = _lookupVarForInterpolation(
        varName,
        currentKey,
        overrides,
        extraEnv,
        readerProvider,
      );
      if (resolved == null) {
        final msg =
            'Warning: unresolved environment variable \$$varName in $currentKey';
        lastUnresolvedWarnings.add(msg);
        stderr.writeln(msg);
        return match.group(0)!;
      }
      return resolved;
    });
  }

  static String? _lookupVarForInterpolation(
    String varName,
    String currentKey,
    Map<String, String> overrides,
    Map<String, String>? extraEnv,
    PropertyReader Function() readerProvider,
  ) {
    final extra = extraEnv?[varName];
    if (extra != null && extra.isNotEmpty) return extra;
    if (varName != currentKey) {
      final sibling = overrides[varName];
      if (sibling != null && !sibling.startsWith(r'$')) return sibling;
    }
    return readerProvider()._getValueWithoutOverrides(varName);
  }

  /// Sets the static environment overrides, resolving any `$VAR` / `${VAR}`
  /// references before storing.
  static void setOverrides(Map<String, String> overrides) {
    _overrides = resolveEnvVariables(overrides);
  }

  /// Clears the static overrides.
  ///
  /// Always called in a `finally` block after job execution.
  static void clearOverrides() {
    _overrides = null;
  }

  /// Merges a single runtime override — `set_env_variable` parity.
  ///
  /// Java `SetEnvVariableProxy` mutates the JVM-wide property map the CLI
  /// executor consults when building the child environment; the Dart
  /// equivalent is a merge into the root override map — the JS bridge's
  /// `cli_execute_command` applies [getOverrides] on top of the child env,
  /// so a script's `set_env_variable('GH_TOKEN', ...)` reaches subsequent
  /// commands (and `PropertyReader.getValue` sees it, like Java).
  static void setOverride(String key, String value) {
    _overrides = resolveEnvVariables({...?_overrides, key: value});
  }

  /// Runs [body] with [overrides] active for the current async context.
  ///
  /// The overrides live in a [Zone] value, so two concurrently running jobs
  /// each keep their own map across `await` boundaries (the Java original
  /// gets the same isolation from `ThreadLocal`).
  static Future<T> runWithOverrides<T>(
    Map<String, String> overrides,
    Future<T> Function() body, {
    Map<String, String>? extraEnv,
    String? basePath,
  }) {
    return runZoned(
      body,
      zoneValues: {
        _overridesZoneKey: resolveEnvVariables(
          overrides,
          extraEnv: extraEnv,
          basePath: basePath,
        ),
      },
    );
  }

  /// Returns the current override map (empty if none set).
  ///
  /// Zone-scoped overrides ([runWithOverrides]) take precedence over the
  /// root static map ([setOverrides]).
  static Map<String, String> getOverrides() {
    final zoned = Zone.current[_overridesZoneKey];
    if (zoned is Map<String, String>) return Map.unmodifiable(zoned);
    final o = _overrides;
    return o != null ? Map.unmodifiable(o) : const <String, String>{};
  }

  // --- Test isolation (hermetic L1 tests) ---

  /// Testing-only switch: when `true`, `dmtools.env` and the on-disk
  /// `config.properties` discovery via CWD/project root are skipped
  /// (readers with an explicit [basePath] still load files) and the
  /// OS-environment source is replaced by [testEnvironment].
  ///
  /// Keeps unit tests hermetic: a developer's real `dmtools.env` in the
  /// project root (the normal L3 setup) otherwise leaks live credentials
  /// into tests that expect empty configuration.
  static bool testIsolation = false;

  /// The environment map consulted instead of `Platform.environment` when
  /// [testIsolation] is enabled. Tests may populate it to exercise the
  /// OS-variable tier of the resolution chain.
  static final Map<String, String> testEnvironment = {};

  /// Optional base directory override (for testing).
  ///
  /// When set, it stands in for the process working directory: `dmtools.env`
  /// and the `config.properties` project root are searched from this
  /// directory (walking up for the Gradle marker) instead of
  /// [Directory.current]. Production code leaves this `null`.
  final String? basePath;

  /// Creates a property reader.
  ///
  /// Pass [basePath] to override the directory where `dmtools.env` is
  /// searched (testing only — production code omits it so the file loads
  /// from the current working directory / project root).
  PropertyReader({this.basePath});

  // --- Instance state ---

  Map<String, String>? _configProps;
  bool _configPropsLoaded = false;
  Map<String, String>? _envProps;
  bool _envPropsLoaded = false;
  String? _projectRoot;

  /// Resolves a property key through the full chain.
  ///
  /// Returns `null` if not found anywhere.
  String? getValue(String key) {
    // 1. Static overrides (highest priority) — accepted on presence, even
    //    when the value is empty.
    final overrides = getOverrides();
    if (overrides.containsKey(key)) {
      return overrides[key];
    }
    return _getValueWithoutOverrides(key);
  }

  /// Resolves [key] across `config.properties`, `dmtools.env`, and the
  /// OS/test environment, skipping the static/zone override map.
  String? _getValueWithoutOverrides(String key) {
    // 2. config.properties (Java resource tier) — every file tier accepts
    //    only non-null AND non-empty values (`property != null &&
    //    !property.isEmpty()`), so empty entries fall through.
    final configValue = _ensureConfigLoaded()[key];
    if (configValue != null && configValue.isNotEmpty) {
      return configValue;
    }
    // 3. dmtools.env — same non-null AND non-empty guard.
    _ensureEnvLoaded();
    final envValue = _envProps![key];
    if (envValue != null && envValue.isNotEmpty) {
      return envValue;
    }
    // 4. OS environment variables (or the isolated test map).
    final env = testIsolation ? testEnvironment : Platform.environment;
    if (env.containsKey(key)) {
      return env[key];
    }
    return null;
  }

  /// Resolves a property key, returning [defaultValue] if not found or empty.
  String getValueWithDefault(String key, String defaultValue) {
    final value = getValue(key);
    if (value == null || value.isEmpty) {
      return defaultValue;
    }
    return value;
  }

  // --- File loading (lazy, cached) ---

  void _ensureEnvLoaded() {
    if (_envPropsLoaded) return;
    _envProps =
        _isolationBlocksDefaultFiles() ? {} : _loadEnvFile('dmtools.env');
    _envPropsLoaded = true;
  }

  /// Lazily loads the `config.properties` tier and caches it (the Dart
  /// equivalent of Java's double-checked `prop` field, lines 170-224).
  Map<String, String> _ensureConfigLoaded() {
    if (_configPropsLoaded) return _configProps!;
    _configProps = _loadConfigFileProps();
    _configPropsLoaded = true;
    return _configProps!;
  }

  /// Priority 1: `<projectRoot>/src/main/resources/config.properties` from
  /// disk — an existing regular file always wins, even when it parses empty
  /// (Java lines 179-186). Priority 2: the [setConfigFile] resource, tried
  /// only when the disk tier did not load (Java lines 200-219).
  Map<String, String> _loadConfigFileProps() {
    if (!_isolationBlocksDefaultFiles()) {
      final root = _findProjectRoot();
      final fromDisk = _readRegularFileProps(
        '$root/src/main/resources/config.properties',
      );
      if (fromDisk != null) return fromDisk;
    }
    return _readRegularFileProps(_resolveResourcePath()) ??
        const <String, String>{};
  }

  /// Resolves the [setConfigFile] resource path against the filesystem.
  ///
  /// Dart substitute for Java's `getResourceAsStream(PATH_TO_CONFIG_FILE)`:
  /// absolute paths are used as-is, relative ones resolve against the
  /// reader's [basePath] (or CWD).
  String _resolveResourcePath() {
    final resource = _pathToConfigFile;
    if (File(resource).isAbsolute) return resource;
    final base = basePath ?? Directory.current.path;
    return '$base/$resource';
  }

  /// Whether test isolation is active and this reader uses the default
  /// (CWD/project-root) search — under isolation only explicit
  /// [basePath] directories are still loaded.
  bool _isolationBlocksDefaultFiles() => testIsolation && basePath == null;

  /// Loads `dmtools.env` — project root first, then the working directory
  /// (Java `loadEnvFileProperties`).
  ///
  /// A candidate is adopted only when the file exists, is a regular file,
  /// parses without error AND yields at least one entry (Java lines 128 and
  /// 146): an empty file never adopts, so the next candidate is tried. When
  /// no candidate is adopted the result is an empty map (published once so
  /// subsequent lookups skip the search — Java line 158).
  Map<String, String> _loadEnvFile(String filename) {
    final cwd = basePath ?? Directory.current.path;
    final root = _findProjectRoot();
    final atRoot = _tryAdoptEnvFile('$root/$filename');
    if (atRoot != null) return atRoot;
    if (cwd != root) {
      final atCwd = _tryAdoptEnvFile('$cwd/$filename');
      if (atCwd != null) return atCwd;
    }
    return {};
  }

  /// Parses the `.env` file at [path] when it is an existing regular file
  /// AND yields at least one entry (Java lines 128 / 146: an empty file
  /// never adopts, so the next candidate is tried).
  Map<String, String>? _tryAdoptEnvFile(String path) {
    final props = _readRegularFileProps(path);
    if (props == null || props.isEmpty) return null;
    return props;
  }

  /// Reads a KEY=VALUE file at [path] when it is an existing regular file.
  ///
  /// Returns `null` when the path is missing or not a regular file, or when
  /// reading fails (warn and continue — Java lines 134-136 / 152-154).
  Map<String, String>? _readRegularFileProps(String path) {
    if (FileStat.statSync(path).type != FileSystemEntityType.file) {
      return null;
    }
    try {
      return parseEnvFile(path);
    } catch (e) {
      stderr.writeln('PropertyReader: failed to read $path, continuing: $e');
      return null;
    }
  }

  /// Walks up from the working directory looking for a Gradle settings
  /// marker (see [_gradleMarkers]) and caches the result; falls back to the
  /// working directory itself when no marker is found (Java
  /// `findProjectRoot`, lines 100-103).
  /// marker is found (Java `findProjectRoot`, lines 100-103).
  String _findProjectRoot() {
    if (_projectRoot != null) return _projectRoot!;
    final start = basePath ?? Directory.current.path;
    _projectRoot = _walkUpForMarker(start) ?? start;
    return _projectRoot!;
  }

  /// Returns the nearest ancestor of [startPath] containing a Gradle
  /// settings marker, or `null` when the filesystem root is reached.
  String? _walkUpForMarker(String startPath) {
    var dir = Directory(startPath);
    while (true) {
      if (_hasGradleMarker(dir.path)) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) return null; // filesystem root
      dir = parent;
    }
  }

  /// Whether [dirPath] contains either Gradle settings marker. The check is
  /// directory-inclusive: Java `Files.exists` is true for directories too.
  bool _hasGradleMarker(String dirPath) {
    for (final marker in _gradleMarkers) {
      if (_pathExists('$dirPath/$marker')) return true;
    }
    return false;
  }

  /// Directory-inclusive existence check (Java `Files.exists` semantics).
  bool _pathExists(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

  /// Resets cached state so the next `getValue` reloads files.
  ///
  /// For unit tests that change env between test cases.
  void resetForTesting() {
    _configProps = null;
    _configPropsLoaded = false;
    _envProps = null;
    _envPropsLoaded = false;
    _projectRoot = null;
  }
}
