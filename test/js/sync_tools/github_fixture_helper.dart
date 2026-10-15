// Shared scripted-GitHub fixture for the sync-tools tests (backs onto
// `github_fixture_server.py`). Extracted so both the PR/release suite
// and the issue/review suite can drive the same subprocess.
import 'dart:convert';
import 'dart:io';

/// Scripted GitHub fixture subprocess (see `github_fixture_server.py`).
class GithubFixtureServer {
  Process? _process;
  File? _logFile;

  /// The bound port (valid after [start]).
  int port = 0;

  /// The request log file (valid after [start]).
  File get logFile {
    final file = _logFile;
    if (file == null) {
      throw StateError('GithubFixtureServer.start() not called yet');
    }
    return file;
  }

  /// Starts the fixture server on an ephemeral port.
  ///
  /// The log dir is created here (not in a field initializer) so it is
  /// strictly coupled to the spawned process.
  ///
  /// [script] is the fixture server file beside this helper (defaults to
  /// the GitHub one; `gitlab_issues_fixture_server.py` serves GitLab).
  Future<void> start({String script = 'github_fixture_server.py'}) async {
    final dir = Directory.systemTemp.createTempSync('dmtools_ghfx_');
    _logFile = File('${dir.path}/r.log');
    final scriptPath = '${Directory.current.path}/test/js/sync_tools/$script';
    _process = await Process.start(
      'python3',
      [scriptPath, '0', _logFile!.path],
    );
    final firstLine = await _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    port = int.parse(firstLine.trim());
  }

  /// The `METHOD path` request log, in order.
  List<String> get requests => logFile.existsSync()
      ? logFile.readAsLinesSync().where((l) => l.isNotEmpty).toList()
      : const <String>[];

  /// Clears the request log.
  void clearLog() => logFile.writeAsStringSync('');

  /// JSON body of the most recent recorded request (written by the
  /// fixture server alongside the request log).
  String? get lastRequestJson {
    final last = File('${logFile.path}.last.json');
    return last.existsSync() ? last.readAsStringSync() : null;
  }

  /// Kills the server process.
  void stop() => _process?.kill();
}
