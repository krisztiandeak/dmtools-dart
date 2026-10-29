/// `dmtools upgrade [version]` (alias `update`).
///
/// The Dart distribution ships as an AOT binary plus a QuickJS library, both
/// installed by `install.sh` under `~/.dmtools/bin`. Upgrading therefore reuses
/// that installer (the same mechanism as first install) instead of replacing
/// the running executable in place.
///
/// Flow: resolve the install script URL, download it to a temp file (failure
/// exits non-zero before anything is touched), then run it with `sh`.
library;

import 'dart:io';

import '../version.dart';

/// Default installer location for the latest release.
const String _latestInstallUrl =
    'https://github.com/epam/dmtools-dart/releases/latest/download/install.sh';

/// Accepted version shapes: `1.2.3`, optional `v`, optional pre-release tag.
/// Anything else would change the installer URL or reach `install.sh` raw.
final RegExp _versionPattern = RegExp(r'^v?\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$');

/// Upgrade runner. All side effects are injectable for tests.
class UpgradeCommand {
  /// Creates an upgrade runner.
  UpgradeCommand({
    void Function(String line)? writer,
    Map<String, String>? environment,
    Future<String?> Function(String url)? fetchScript,
    Future<int> Function(String scriptPath, Map<String, String> env)? runScript,
  })  : _writer = writer ?? print,
        _env = environment ?? Platform.environment,
        _fetch = fetchScript ?? _defaultFetch,
        _run = runScript ?? _defaultRun;

  final void Function(String line) _writer;
  final Map<String, String> _env;
  final Future<String?> Function(String url) _fetch;
  final Future<int> Function(String scriptPath, Map<String, String> env) _run;

  /// Runs the upgrade. [args] holds the optional version (`upgrade 0.1.60`
  /// or `upgrade v0.1.60`). Returns the process exit code.
  Future<int> run(List<String> args) async {
    final help = _helpExit(args);
    if (help != null) return help;
    final version = _resolveRequestedVersion(args);
    if (version.isNotEmpty && !_versionPattern.hasMatch(version)) {
      _writer('Invalid version "$version". Expected e.g. 0.1.60 or v0.1.60.');
      return 2;
    }
    final url = _resolveUrl(version);
    final before = dmtoolsVersion;

    _writer('Installed version: $before');
    _writer('Installer: $url');

    return _executeInstaller(version, url, before);
  }

  /// Runs the fetched installer (or reports the dry run) — extracted from
  /// [run] to keep its cyclomatic complexity under the CRAP gate.
  Future<int> _executeInstaller(
    String version,
    String url,
    String before,
  ) async {
    if (_env['DMTOOLS_UPGRADE_DRY_RUN'] == 'true') {
      _writer(
        'Dry run: would run the installer above'
        '${version.isEmpty ? '' : ' for $version'}. No changes made.',
      );
      return 0;
    }

    final script = await _fetch(url);
    if (script == null) {
      _reportDownloadFailed(url);
      return 1;
    }
    final env = Map<String, String>.from(_env);
    if (version.isNotEmpty) env['DMTOOLS_VERSION'] = version;
    final code = await _run(script, env);
    if (code != 0) {
      _reportInstallFailed(code);
      return code;
    }
    _writer(
      'Installer finished (requested: ${_displayVersion(version)}; '
      'was $before). Run `dmtools --version` to confirm the installed version.',
    );
    return 0;
  }

  /// The version to upgrade to: the positional arg wins, else
  /// `DMTOOLS_VERSION`, else latest (empty string).
  String _resolveRequestedVersion(List<String> args) {
    final positional = args.where((a) => !a.startsWith('-')).toList();
    final requested = positional.isEmpty ? null : positional.first.trim();
    if (requested == null || requested.isEmpty) {
      return _env['DMTOOLS_VERSION'] ?? '';
    }
    return requested;
  }

  /// Prints the usage line for `--help`/`-h`; null when args are real work.
  int? _helpExit(List<String> args) {
    if (args.any((a) => a == '--help' || a == '-h')) {
      _writer('Usage: dmtools upgrade [version]   (alias: update)');
      return 0;
    }
    return null;
  }

  /// Reports a failed download; the installation is left untouched.
  void _reportDownloadFailed(String url) {
    _writer(
      'Upgrade failed: could not download $url. '
      'The existing installation was left untouched.',
    );
  }

  /// Reports a failed installer run; the installation is left untouched.
  void _reportInstallFailed(int code) {
    _writer(
      'Upgrade failed: installer exited with code $code. '
      'The existing installation was left untouched.',
    );
  }

  /// The human-facing version label: `latest` or the requested one, `v`-less.
  String _displayVersion(String version) =>
      version.isEmpty ? 'latest' : version.replaceFirst(RegExp(r'^v'), '');

  /// Resolves the installer URL. `DMTOOLS_INSTALL_SCRIPT_URL` wins; a
  /// version selects the tagged release asset, otherwise the latest one.
  String _resolveUrl(String version) {
    final override = _env['DMTOOLS_INSTALL_SCRIPT_URL'];
    if (override != null && override.isNotEmpty) return override;
    if (version.isEmpty) return _latestInstallUrl;
    final tag = version.startsWith('v') ? version : 'v$version';
    return 'https://github.com/epam/dmtools-dart/releases/download/$tag/install.sh';
  }

  static Future<String?> _defaultFetch(String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = await res.transform(const SystemEncoding().decoder).join();
      final dir = await Directory.systemTemp.createTemp('dmtools-install-');
      final file = File('${dir.path}/install.sh');
      await file.writeAsString(body, flush: true);
      return file.path;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<int> _defaultRun(
    String scriptPath,
    Map<String, String> env,
  ) async {
    final result = await Process.run('sh', [scriptPath], environment: env);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    return result.exitCode;
  }
}
