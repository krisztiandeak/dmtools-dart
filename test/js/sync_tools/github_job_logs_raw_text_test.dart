import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/sync_tools/github_sync_tools.dart';
import 'package:test/test.dart';

import 'github_fixture_helper.dart';

/// Raw-text marshal regression for `github_get_job_logs` (split out of
/// github_sync_tools_test.dart to keep that file under the loc limit).
///
/// Live 2026-10-17: a raw-text log body crossed the QuickJS FFI bridge
/// unencoded and JSON.parse killed it ("host callback returned invalid
/// JSON") — the rework leg then had no ci_failures_full.log and no-oped
/// 3 rounds into the rework cap (dart #414). Raw-text tool results must
/// be JSON-encoded strings for the bridge.
void main() {
  late GithubFixtureServer fx;
  late GitHubSyncTools tools;

  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });

  group('GitHubSyncTools actions tools (fixture, raw text)', () {
    setUp(() async {
      fx = GithubFixtureServer();
      await fx.start();
      PropertyReader.setOverrides({
        'SOURCE_GITHUB_TOKEN': 'ghp_testtoken',
        'SOURCE_GITHUB_BASE_PATH': 'http://127.0.0.1:${fx.port}',
      });
      tools = const GitHubSyncTools();
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      fx.stop();
    });

    test('github_get_job_logs hits the job logs endpoint', () {
      tools.handlers['github_get_job_logs']!({
        'workspace': 'o',
        'repository': 'r',
        'jobId': '7',
      });
      final recorded = jsonDecode(
        File('${fx.logFile.path}.last.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(recorded['method'], 'GET');
      expect(recorded['path'], '/repos/o/r/actions/jobs/7/logs');
    });

    test('github_get_job_logs returns raw log text as a JSON string', () {
      final result = tools.handlers['github_get_job_logs']!({
        'workspace': 'o',
        'repository': 'r',
        'jobId': '7',
      });
      final decoded = jsonDecode(result);
      expect(decoded, isA<String>());
      expect(decoded as String, contains('##[error]method_size'));
    });

    _redirectTest(() => fx, () => tools);
  });
}

void _redirectTest(
  GithubFixtureServer Function() fx,
  GitHubSyncTools Function() tools,
) {
  test('github_get_job_logs follows the 302 to the blob log', () {
    final result = tools().handlers['github_get_job_logs']!({
      'workspace': 'o',
      'repository': 'r',
      'jobId': '302',
    });
    expect(jsonDecode(result), contains('redirected blob log body'));
    expect(fx().requests.last, contains('/blob/job-302.txt'));
  });
}
