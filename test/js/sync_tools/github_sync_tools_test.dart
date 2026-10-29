import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/sync_tools/github_sync_tools.dart';
import 'package:test/test.dart';

import '../echo_server_helper.dart';
import 'github_fixture_helper.dart';

// Shared fixtures for the fixture-server groups (each group's setUp
// rebinds fx and tools).
late GithubFixtureServer fx;
late GitHubSyncTools tools;
late Directory tmp;

/// Tests for [GitHubSyncTools] — the sync `github_*` executors.
///
/// Java spec: `GitHub.java` — parameter names (`workspace`, `repository`,
/// `pullRequestId`, `text`) must match exactly; that is what the
/// dmtools-agents scripts pass. Server-dependent tests use the scripted
/// GitHub fixture subprocess (or the plain echo server) because Dart's
/// [HttpServer] runs on the event loop, frozen during
/// `Process.runSync('curl', …)`.
void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });
  _registryTests();
  _noConfigTests();
  if (hasPython3()) {
    _fixtureGroups();
  }
}

/// The full handler surface, with Java tool names.
void _registryTests() {
  group('GitHubSyncTools.handlers', () {
    test('registers every agent-suite github tool', () {
      final names = const GitHubSyncTools().handlers.keys.toSet();
      expect(
        names,
        containsAll(const [
          'github_get_pr',
          'github_list_prs',
          'github_create_comment',
          'github_add_pr_comment',
          'github_add_pr_label',
          'github_remove_pr_label',
          'github_get_pr_comments',
          'github_get_pr_conversations',
          'github_get_pr_review_threads',
          'github_resolve_pr_thread',
          'github_reply_to_pr_thread',
          'github_add_inline_comment',
          'github_get_pr_diff',
          'github_get_pr_diff_text',
          'github_merge_pr',
          'github_get_commit_check_runs',
          'github_get_job_logs',
          'github_list_workflow_runs',
          'github_trigger_workflow',
          'github_get_workflow_run_jobs',
          'github_get_workflow_run_logs',
          'github_get_or_create_draft_release',
          'github_upload_release_asset',
        ]),
      );
    });
  });
}

/// Config error contract shared with [SyncToolDispatcher].
void _noConfigTests() {
  group('GitHubSyncTools without config', () {
    setUp(() => PropertyReader.setOverrides({'SOURCE_GITHUB_TOKEN': ''}));
    tearDown(PropertyReader.clearOverrides);

    test('github_get_pr returns the config error', () {
      expect(
        jsonDecode(
          const GitHubSyncTools().handlers['github_get_pr']!({
            'workspace': 'o',
            'repository': 'r',
            'pullRequestId': '7',
          }),
        ),
        {'error': 'GitHub not configured'},
      );
    });
  });
}

/// All fixture-server backed groups.
///
/// Each helper is wrapped in its own [group] so its `setUp`/`tearDown`
/// (which start/stop a fixture server) apply only to that group's tests —
/// top-level `setUp`s would all run for every test, each spawning a
/// server while only the last one's port ends up in the config override.
void _fixtureGroups() {
  group('GitHubSyncTools PR tools (fixture)', _fixturePrTools);
  group('GitHubSyncTools comment tools (fixture)', _fixtureCommentTools);
  group('GitHubSyncTools thread tools (fixture)', _fixtureThreadTools);
  group('GitHubSyncTools diff tools (fixture)', _fixtureDiffTools);
  group('GitHubSyncTools actions tools (fixture)', _fixtureActionsTools);
  group('GitHubSyncTools release tools (fixture)', _fixtureReleaseTools);
}

/// PR read/list/merge tools.
void _fixturePrTools() {
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

  fixtureprtools_p1();
  fixtureprtools_p2();
}

void fixtureprtools_p1() {
  test('github_get_pr hits the pulls endpoint with Java param names', () {
    final raw = tools.handlers['github_get_pr']!({
      'workspace': 'o',
      'repository': 'r',
      'pullRequestId': '42',
    });
    final pr = jsonDecode(raw) as Map<String, dynamic>;
    expect(pr['number'], 42);
    expect(pr['head']['sha'], 'abc123def456');
    final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
    expect(sent['method'], 'GET');
    expect(sent['path'], '/repos/o/r/pulls/42');
    expect(sent['headers']['Authorization'], 'Bearer ghp_testtoken');
    expect(sent['headers']['Accept'], 'application/vnd.github+json');
  });

  test('github_list_prs normalizes state synonyms', () {
    tools.handlers['github_list_prs']!({
      'workspace': 'o',
      'repository': 'r',
      'state': 'opened',
    });
    expect(
      fx.requests.single,
      'GET /repos/o/r/pulls'
      '?state=open&sort=updated&direction=desc&per_page=100&page=1',
    );
  });

  test('github_list_prs with merged state filters to merged PRs', () {
    final result = tools.handlers['github_list_prs']!({
      'workspace': 'o',
      'repository': 'r',
      'state': 'merged',
    });
    final prs = jsonDecode(result) as List;
    expect(prs, hasLength(1));
    expect(prs.single['number'], 1);
  });

  test('github_merge_pr PUTs the merge endpoint with defaults', () {
    final body = jsonDecode(
      tools.handlers['github_merge_pr']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '42',
      }),
    ) as Map<String, dynamic>;
    expect(body['method'], 'PUT');
    expect(body['path'], '/repos/o/r/pulls/42/merge');
    expect(jsonDecode(body['body'] as String), {'merge_method': 'merge'});
  });
}

void fixtureprtools_p2() {
  test('github_merge_pr passes squash method and commit metadata', () {
    final body = jsonDecode(
      tools.handlers['github_merge_pr']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '42',
        'mergeMethod': 'squash',
        'commitTitle': 'Merge it',
        'commitMessage': 'Closes #1',
      }),
    ) as Map<String, dynamic>;
    expect(jsonDecode(body['body'] as String), {
      'merge_method': 'squash',
      'commit_title': 'Merge it',
      'commit_message': 'Closes #1',
    });
  });

  test('github_list_branches hits the branches endpoint', () {
    tools.handlers['github_list_branches']!({
      'workspace': 'o',
      'repository': 'r',
    });
    expect(fx.requests, [
      'GET /repos/o/r/branches?per_page=100&page=1',
      'GET /repos/o/r/branches?per_page=100&page=2',
    ]);
  });
}

/// Comment and label tools.
void _fixtureCommentTools() {
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

  fixturecommenttools_p1();
  fixturecommenttools_p2();
}

void fixturecommenttools_p1() {
  test('github_add_pr_comment POSTs the Java text argument', () {
    tools.handlers['github_add_pr_comment']!({
      'workspace': 'o',
      'repository': 'r',
      'pullRequestId': '42',
      'text': 'Ship it',
    });
    final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
    expect(sent['method'], 'POST');
    expect(sent['path'], '/repos/o/r/issues/42/comments');
    expect(jsonDecode(sent['body'] as String), {'body': 'Ship it'});
  });

  test('github_create_comment accepts text and body arguments', () {
    for (final key in const ['text', 'body']) {
      tools.handlers['github_create_comment']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '42',
        key: 'Nice PR!',
      });
      final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(sent['method'], 'POST');
      expect(sent['path'], '/repos/o/r/issues/42/comments');
      expect(jsonDecode(sent['body'] as String), {'body': 'Nice PR!'});
    }
  });

  test('github_add_pr_label POSTs a single-element label array', () {
    final body = jsonDecode(
      tools.handlers['github_add_pr_label']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '42',
        'label': 'bug',
      }),
    ) as Map<String, dynamic>;
    expect(body['method'], 'POST');
    expect(body['path'], '/repos/o/r/issues/42/labels');
    expect(jsonDecode(body['body'] as String), ['bug']);
  });

  test('github_remove_pr_label DELETEs the label resource', () {
    final body = jsonDecode(
      tools.handlers['github_remove_pr_label']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '42',
        'label': 'bug',
      }),
    ) as Map<String, dynamic>;
    expect(body['method'], 'DELETE');
    expect(body['path'], '/repos/o/r/issues/42/labels/bug');
  });
}

void fixturecommenttools_p2() {
  test('github_get_pr_comments merges and sorts both comment kinds', () {
    final result = tools.handlers['github_get_pr_comments']!({
      'workspace': 'o',
      'repository': 'r',
      'pullRequestId': '42',
    });
    final comments = jsonDecode(result) as List;
    expect(comments.map((c) => c['id']), [10, 1, 2, 3]);
  });

  test('github_get_pr_comments surfaces non-OK pages as an error', () {
    // Java AbstractRestClient throws a RestClientException on any non-OK
    // page — the old Dart loop broke on it and reported "no comments".
    final result = tools.handlers['github_get_pr_comments']!({
      'workspace': 'o',
      'repository': 'r',
      'pullRequestId': '7',
    });
    final decoded = jsonDecode(result) as Map<String, dynamic>;
    expect(decoded['error'], contains('HTTP 500'));
  });

  test('github_get_pr_conversations surfaces non-OK pages as an error', () {
    // Same AbstractRestClient parity for the conversations tool: both call
    // sites changed identically, so the non-OK branch needs coverage here
    // too — the old swallow loop reported "no conversations".
    final result = tools.handlers['github_get_pr_conversations']!({
      'workspace': 'o',
      'repository': 'r',
      'pullRequestId': '7',
    });
    final decoded = jsonDecode(result) as Map<String, dynamic>;
    expect(decoded['error'], contains('HTTP 500'));
  });
}

/// Review-thread tools (REST grouping + GraphQL).
void _fixtureThreadTools() {
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

  fixturethreadtools_p1();
  fixturethreadtools_p2();
  fixturethreadtools_p3();
  fixturethreadtools_p4();
}

void fixturethreadtools_p1() {
  test('github_get_pr_conversations groups inline replies into threads', () {
    final result = tools.handlers['github_get_pr_conversations']!({
      'workspace': 'o',
      'repository': 'r',
      'pullRequestId': '42',
    });
    final conversations = jsonDecode(result) as List;
    // id 1 roots a thread replied to by id 2; id 3's parent is unknown so
    // it roots its own thread; id 10 is the issue-style discussion entry.
    expect(conversations, hasLength(3));
    final root = conversations.first as Map<String, dynamic>;
    expect(root['rootComment']['id'], 1);
    expect((root['replies'] as List).single['id'], 2);
    expect(root['totalComments'], 2);
  });

  test('github_get_pr_review_threads POSTs the GraphQL query', () {
    final body = jsonDecode(
      tools.handlers['github_get_pr_review_threads']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '42',
      }),
    ) as Map<String, dynamic>;
    expect(body['method'], 'POST');
    expect(body['path'], '/graphql');
    final sent = jsonDecode(body['body'] as String) as Map<String, dynamic>;
    expect(sent['query'] as String, contains('reviewThreads'));
    expect(sent['variables'], {'owner': 'o', 'repo': 'r', 'prNumber': 42});
  });

  test('github_resolve_pr_thread POSTs the resolve mutation', () {
    final body = jsonDecode(
      tools.handlers['github_resolve_pr_thread']!({
        'threadId': 'PRRT_kwDO',
      }),
    ) as Map<String, dynamic>;
    final sent = jsonDecode(body['body'] as String) as Map<String, dynamic>;
    expect(sent['query'] as String, contains('resolveReviewThread'));
    expect(sent['query'] as String, contains('PRRT_kwDO'));
  });
}

void fixturethreadtools_p2() {
  test('github_reply_to_pr_thread rejects a non-numeric reply id', () {
    expect(
      jsonDecode(
        tools.handlers['github_reply_to_pr_thread']!({
          'workspace': 'o',
          'repository': 'r',
          'pullRequestId': '42',
          'inReplyToId': 'not-a-number',
          'text': 'x',
        }),
      ),
      {
        'error': "Invalid inReplyToId: expected a numeric GitHub comment ID, "
            "but got: 'not-a-number'",
      },
    );
  });

  test('github_reply_to_pr_thread POSTs in_reply_to (alias accepted)', () {
    for (final key in const ['inReplyToId', 'threadId']) {
      tools.handlers['github_reply_to_pr_thread']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '42',
        key: '123',
        'text': 'Fixed.',
      });
      final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(sent['method'], 'POST');
      expect(sent['path'], '/repos/o/r/pulls/42/comments');
      expect(jsonDecode(sent['body'] as String), {
        'body': 'Fixed.',
        'in_reply_to': 123,
      });
    }
  });
}

void fixturethreadtools_p3() {
  test(
      'github_add_inline_comment resolves head sha and submits pending '
      'review before posting', () {
    fx.clearLog();
    tools.handlers['github_add_inline_comment']!({
      'workspace': 'o',
      'repository': 'r',
      'pullRequestId': '42',
      'path': 'src/a.txt',
      'line': '42',
      'text': 'Refactor this.',
      'startLine': '40',
    });
    final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
    expect(sent['method'], 'POST');
    expect(sent['path'], '/repos/o/r/pulls/42/comments');
    expect(jsonDecode(sent['body'] as String), {
      'body': 'Refactor this.',
      'commit_id': 'abc123def456',
      'path': 'src/a.txt',
      'line': 42,
      'side': 'RIGHT',
      'start_line': 40,
      'start_side': 'RIGHT',
    });
    final reviewsGet = fx.requests.indexOf('GET /repos/o/r/pulls/42/reviews');
    final eventsPost = fx.requests.indexOf(
      'POST /repos/o/r/pulls/42/reviews/9/events',
    );
    final commentPost = fx.requests.lastIndexOf(
      'POST /repos/o/r/pulls/42/comments',
    );
    expect(reviewsGet, greaterThanOrEqualTo(0));
    expect(eventsPost, greaterThan(reviewsGet));
    expect(commentPost, greaterThan(eventsPost));
  });
}

void fixturethreadtools_p4() {
  test('github_add_inline_comment with explicit commitId skips the PR GET', () {
    fx.clearLog();
    tools.handlers['github_add_inline_comment']!({
      'workspace': 'o',
      'repository': 'r',
      'pullRequestId': '42',
      'path': 'src/a.txt',
      'line': 7,
      'text': 'x',
      'commitId': 'deadbeef',
      'side': 'left',
    });
    final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
    final body = jsonDecode(sent['body'] as String) as Map<String, dynamic>;
    expect(body['commit_id'], 'deadbeef');
    expect(body['side'], 'LEFT');
    expect(fx.requests, isNot(contains('GET /repos/o/r/pulls/42')));
  });

  test('github_add_inline_comment rejects a non-numeric line', () {
    expect(
      jsonDecode(
        tools.handlers['github_add_inline_comment']!({
          'workspace': 'o',
          'repository': 'r',
          'pullRequestId': '42',
          'path': 'src/a.txt',
          'line': 'x1',
          'text': 't',
        }),
      ),
      {'error': "Invalid line: expected a numeric value, but got: 'x1'"},
    );
  });
}

/// Diff tools, including the IS_READ_PULL_REQUEST_DIFF gate.
void _fixtureDiffTools() {
  setUp(() async {
    fx = GithubFixtureServer();
    await fx.start();
    PropertyReader.setOverrides({
      'SOURCE_GITHUB_TOKEN': 'ghp_testtoken',
      'SOURCE_GITHUB_BASE_PATH': 'http://127.0.0.1:${fx.port}',
      'IS_READ_PULL_REQUEST_DIFF': 'true',
    });
    tools = const GitHubSyncTools();
  });

  tearDown(() {
    PropertyReader.clearOverrides();
    fx.stop();
  });

  test('github_get_pr_diff_text returns the raw diff (pullRequestID name)', () {
    final result = tools.handlers['github_get_pr_diff_text']!({
      'workspace': 'o',
      'repository': 'r',
      'pullRequestID': '42',
    });
    expect(result, contains('diff --git a/src/a.txt'));
    expect(fx.requests.single, 'GET /repos/o/r/pulls/42');
  });

  test('github_get_pr_diff parses additions and deletions', () {
    final stats = jsonDecode(
      tools.handlers['github_get_pr_diff']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestID': '42',
      }),
    ) as Map<String, dynamic>;
    expect(stats['stats'], {'total': 3, 'additions': 2, 'deletions': 1});
  });

  test('diff tools return empty when IS_READ_PULL_REQUEST_DIFF is off', () {
    PropertyReader.setOverrides({
      'SOURCE_GITHUB_TOKEN': 'ghp_testtoken',
      'SOURCE_GITHUB_BASE_PATH': 'http://127.0.0.1:${fx.port}',
      'IS_READ_PULL_REQUEST_DIFF': 'false',
    });
    final args = {'workspace': 'o', 'repository': 'r', 'pullRequestID': '42'};
    final text = tools.handlers['github_get_pr_diff_text']!(args);
    expect(jsonDecode(text), '');
    final stats = jsonDecode(tools.handlers['github_get_pr_diff']!(args));
    expect(stats['stats']['total'], 0);
  });
}

/// Commit checks, Actions runs, jobs, logs.
void _fixtureActionsTools() {
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

  fixtureactionstools_p1();
  fixtureactionstools_p2();
}

void fixtureactionstools_p1() {
  test('github_get_commit_check_runs hits the check-runs endpoint', () {
    final body = jsonDecode(
      tools.handlers['github_get_commit_check_runs']!({
        'workspace': 'o',
        'repository': 'r',
        'commitSha': 'cafe123',
      }),
    ) as Map<String, dynamic>;
    expect(body['method'], 'GET');
    expect(
      body['path'],
      '/repos/o/r/commits/cafe123/check-runs?per_page=100&page=1',
    );
  });

  test('github_get_workflow_run_jobs hits the run jobs endpoint', () {
    final body = jsonDecode(
      tools.handlers['github_get_workflow_run_jobs']!({
        'workspace': 'o',
        'repository': 'r',
        'runId': '5',
      }),
    ) as Map<String, dynamic>;
    expect(body['path'], '/repos/o/r/actions/runs/5/jobs?per_page=100&page=1');
  });

  test('github_list_workflow_runs supports workflow + status filters', () {
    final body = jsonDecode(
      tools.handlers['github_list_workflow_runs']!({
        'workspace': 'o',
        'repository': 'r',
        'workflowId': 'rework.yml',
        'status': 'failure',
        'perPage': '50',
        'page': '2',
        'created': '2026-05-01..2026-05-31',
      }),
    ) as Map<String, dynamic>;
    expect(
      body['path'],
      '/repos/o/r/actions/workflows/rework.yml/runs'
      '?status=failure&per_page=50&page=2&created=2026-05-01..2026-05-31',
    );
  });
}

void fixtureactionstools_p2() {
  test('github_list_workflow_runs without filters hits the runs endpoint', () {
    final body = jsonDecode(
      tools.handlers['github_list_workflow_runs']!({
        'workspace': 'o',
        'repository': 'r',
      }),
    ) as Map<String, dynamic>;
    expect(body['path'], '/repos/o/r/actions/runs');
  });

  test(
      'github_trigger_workflow POSTs a dispatch and returns the Java '
      'success message', () {
    final result = tools.handlers['github_trigger_workflow']!({
      'workspace': 'o',
      'repository': 'r',
      'workflowId': 'rework.yml',
      'inputs': '{"user_request":"rework PROJ-1"}',
      'ref': 'develop',
    });
    final body = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
    expect(body['method'], 'POST');
    expect(body['path'], '/repos/o/r/actions/workflows/rework.yml/dispatches');
    expect(jsonDecode(body['body'] as String), {
      'ref': 'develop',
      'inputs': {'user_request': 'rework PROJ-1'},
    });
    // The success message must arrive JSON-encoded: the QuickJS FFI
    // bridge parses every host result with JS_ParseJSON — raw text throws
    // "host callback returned invalid JSON" (live: #687 SM dispatch).
    expect(result, '"Workflow \'rework.yml\' triggered successfully on o/r"');
    expect(jsonDecode(result),
        "Workflow 'rework.yml' triggered successfully on o/r");
  });

  test(
      'github_get_workflow_run_logs follows the redirect and extracts the '
      'ZIP text entries', () {
    final result = tools.handlers['github_get_workflow_run_logs']!({
      'workspace': 'o',
      'repository': 'r',
      'runId': '55',
    });
    // Log text is JSON-encoded for the FFI bridge — assert on the decoded
    // payload (the exact string JS sees after the bridge unwraps it).
    final decoded = jsonDecode(result) as String;
    expect(decoded, contains('--- job1.txt ---\n\nstep one log'));
    expect(decoded, contains('--- job2.txt ---\n\nstep two log'));
    expect(decoded, isNot(contains('skip.bin')));
  });
}

/// Draft-release storage and asset upload.
void _fixtureReleaseTools() {
  setUp(() async {
    fx = GithubFixtureServer();
    await fx.start();
    PropertyReader.setOverrides({
      'SOURCE_GITHUB_TOKEN': 'ghp_testtoken',
      'SOURCE_GITHUB_BASE_PATH': 'http://127.0.0.1:${fx.port}',
    });
    tools = const GitHubSyncTools();
    tmp = Directory.systemTemp.createTempSync('dmtools_gh_asset_');
  });

  tearDown(() {
    PropertyReader.clearOverrides();
    fx.stop();
    tmp.deleteSync(recursive: true);
  });

  fixturereleasetools_p1();
  fixturereleasetools_p2();
  fixturereleasetools_p3();
}

void fixturereleasetools_p1() {
  test('github_get_or_create_draft_release returns an existing draft', () {
    final result = tools.handlers['github_get_or_create_draft_release']!({
      'workspace': 'o',
      'repository': 'r',
      'tagName': 'existing-tag',
      'releaseName': 'Existing Draft',
    });
    final release = jsonDecode(result) as Map<String, dynamic>;
    expect(release['id'], 5);
    expect(release['draft'], isTrue);
    expect(fx.requests.single, 'GET /repos/o/r/releases?per_page=100&page=1');
  });
}

void fixturereleasetools_p2() {
  test('github_get_or_create_draft_release creates when missing', () {
    final result = tools.handlers['github_get_or_create_draft_release']!({
      'workspace': 'o',
      'repository': 'r',
      'tagName': 'new-tag',
      'releaseName': 'New Release',
      'targetCommitish': 'main',
      'body': 'notes',
    });
    final body = jsonDecode(result) as Map<String, dynamic>;
    expect(body['method'], 'POST');
    expect(body['path'], '/repos/o/r/releases');
    expect(jsonDecode(body['body'] as String), {
      'tag_name': 'new-tag',
      'name': 'New Release',
      'draft': true,
      'target_commitish': 'main',
      'body': 'notes',
    });
  });

  test(
    'github_upload_release_asset deletes the existing asset then uploads',
    () {
      final file = File('${tmp.path}/report.txt')
        ..writeAsStringSync('asset bytes');
      fx.clearLog();
      final result = tools.handlers['github_upload_release_asset']!({
        'workspace': 'o',
        'repository': 'r',
        'releaseId': '5',
        'filePath': file.path,
        'overwrite': 'true',
      });
      final asset = jsonDecode(result) as Map<String, dynamic>;
      expect(asset['browser_download_url'], 'https://dl/x');
      expect(
        fx.requests,
        containsAllInOrder([
          'GET /repos/o/r/releases/5/assets',
          'DELETE /repos/o/r/releases/assets/77',
        ]),
      );
      expect(fx.requests.last, startsWith('POST /uploads/'));
    },
  );
}

void fixturereleasetools_p3() {
  test('github_upload_release_asset errors on a missing file', () {
    expect(
      jsonDecode(
        tools.handlers['github_upload_release_asset']!({
          'workspace': 'o',
          'repository': 'r',
          'releaseId': '5',
          'filePath': '${tmp.path}/nope.txt',
        }),
      ),
      {'error': startsWith('Release asset file not found:')},
    );
  });
}
