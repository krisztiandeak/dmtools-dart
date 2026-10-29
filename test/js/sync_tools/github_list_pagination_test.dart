import 'dart:convert';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/sync_tools/github_sync_tools.dart';
import 'package:test/test.dart';

import '../echo_server_helper.dart';
import 'github_fixture_helper.dart';

/// gh-388: single-page GitHub list tools silently dropped items past
/// page 1. Fixture repo `o/pg` serves a full 100-item page 1 and a
/// 2-item page 2; `o/pgfail` fails page 2 (walk keeps page 1).
late GithubFixtureServer fx;
late GitHubSyncTools tools;

String _call(String tool, String repo,
        [Map<String, dynamic> extra = const {}]) =>
    tools.handlers[tool]!({'workspace': 'o', 'repository': repo, ...extra});

Iterable<String> _hits(String fragment) =>
    fx.requests.where((r) => r.contains(fragment));

void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });

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

  if (!hasPython3()) return;
  _fullWalkTests();
  _edgeTests();
}

/// Every list tool walks past a full first page.
void _fullWalkTests() {
  test('github_list_branches walks every page', () {
    expect(jsonDecode(_call('github_list_branches', 'pg')), hasLength(102));
    expect(_hits('/branches?per_page=100&page='), hasLength(2));
  });

  test('github_list_pr_reviews walks every page', () {
    final out = _call('github_list_pr_reviews', 'pg', {'pullRequestId': '7'});
    expect(jsonDecode(out), hasLength(102));
    expect(_hits('/pulls/7/reviews?per_page=100&page='), hasLength(2));
  });

  test('github_list_prs state=open walks every page', () {
    expect(
      jsonDecode(_call('github_list_prs', 'pg', {'state': 'open'})),
      hasLength(102),
    );
    expect(_hits('/pulls?state=open'), hasLength(2));
  });

  test('github_list_prs state=closed keeps the first page only', () {
    expect(
      jsonDecode(_call('github_list_prs', 'pg', {'state': 'closed'})),
      hasLength(100),
    );
    expect(_hits('/pulls?state=closed'), hasLength(1));
  });

  test('github_get_workflow_run_jobs merges jobs, keeps total_count', () {
    final body = jsonDecode(
      _call('github_get_workflow_run_jobs', 'pg', {'runId': '9'}),
    ) as Map<String, dynamic>;
    expect(body['jobs'], hasLength(102));
    expect(body['total_count'], 102);
    expect(_hits('/actions/runs/9/jobs?per_page=100&page='), hasLength(2));
  });
}

/// Short pages, failures, and pass-through bodies.
void _edgeTests() {
  test('a later-page failure returns the pages already collected', () {
    expect(jsonDecode(_call('github_list_branches', 'pgfail')), hasLength(100));
    final jobs = jsonDecode(
      _call('github_get_workflow_run_jobs', 'pgfail', {'runId': '9'}),
    ) as Map<String, dynamic>;
    expect(jobs['jobs'], hasLength(100));
  });

  test('a page-1 error body passes through untouched', () {
    final out = _call('github_list_branches', 'err');
    expect(out, contains('branches boom'));
    expect(_hits('/repos/o/err/branches'), hasLength(1));
  });

  test('a short first page is one request with the body unchanged', () {
    final out = _call('github_list_branches', 'errc');
    expect(jsonDecode(out), [
      {'name': 'x'},
    ]);
    expect(_hits('/repos/o/errc/branches'), hasLength(1));
  });
}
