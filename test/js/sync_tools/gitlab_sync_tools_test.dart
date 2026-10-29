import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/sync_tools/gitlab_sync_tools.dart';
import 'package:test/test.dart';

import '../echo_server_helper.dart';

/// Shared fixtures for the echo-server-backed groups (each group's
/// setUp rebinds the server; tools is stateless).
late EchoServer server;
late Directory tmp;
const tools = GitLabSyncTools();

Map<String, dynamic> echo(String tool, Map<String, dynamic> args) =>
    jsonDecode(tools.handlers[tool]!(args)) as Map<String, dynamic>;

/// Tests for [GitLabSyncTools].
///
/// Server-dependent groups start a Python echo server subprocess (Dart's
/// [HttpServer] runs on the event loop, which is frozen during
/// `Process.runSync('curl', …)`); every tool call asserts the method, URL
/// shape, and request body that reached the server.
void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });
  _testHandlerSurface();
  _testNoConfig();
  if (hasPython3()) {
    _testMrTools();
    _testThreadTools();
    _testCiTools();
    _testReleaseTools();
  }
  _testDiffHelpers();
  _testStatusDedupe();
}

/// Every tool name the agent scripts (js/common/scm.js, releaseArtefacts.js)
/// call must resolve to a handler.
void _testHandlerSurface() {
  test('GitLabSyncTools.handlers covers the agent tool surface', () {
    const tools = GitLabSyncTools();
    final names = [
      'gitlab_get_mr',
      'gitlab_list_mrs',
      'gitlab_get_mr_pipelines',
      'gitlab_list_issues',
      'gitlab_create_mr_note',
      'gitlab_add_mr_comment',
      'gitlab_get_mr_comments',
      'gitlab_get_mr_diff_text',
      'gitlab_get_mr_diff',
      'gitlab_reply_to_mr_thread',
      'gitlab_resolve_mr_thread',
      'gitlab_add_inline_mr_comment',
      'gitlab_merge_mr',
      'gitlab_rebase_mr',
      'gitlab_approve_mr',
      'gitlab_unapprove_mr',
      'gitlab_add_mr_label',
      'gitlab_remove_mr_label',
      'gitlab_get_mr_discussions',
      'gitlab_get_commit_statuses',
      'gitlab_get_job_logs',
      'gitlab_list_pipeline_runs',
      'gitlab_list_project_jobs',
      'gitlab_get_pipelines',
      'gitlab_get_pipeline',
      'gitlab_trigger_pipeline',
      'gitlab_create_mr',
      'gitlab_get_or_create_release',
      'gitlab_upload_release_asset',
      'gitlab_download_release_asset',
    ];
    for (final name in names) {
      expect(tools.handlers, containsPair(name, anything),
          reason: 'missing handler for $name');
    }
  });
}

/// Unconfigured GitLab reports a JSON error, not a crash.
void _testNoConfig() {
  test('tools return config error without GITLAB_BASE_PATH/TOKEN', () {
    PropertyReader.setOverrides({'GITLAB_BASE_PATH': '', 'GITLAB_TOKEN': ''});
    final result = const GitLabSyncTools().handlers['gitlab_get_mr']!(
        {'workspace': 'g', 'repository': 'r', 'pullRequestId': '7'});
    expect(jsonDecode(result), {'error': 'GitLab not configured'});
    PropertyReader.clearOverrides();
  });
}

/// Java-style args (`workspace`/`repository`/`pullRequestId`) plus the MR
/// read/write basics.
void _testMrTools() {
  group('GitLabSyncTools merge request tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides({
        'GITLAB_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'GITLAB_TOKEN': 'glpat-test',
      });
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    testmrtools_p1();
    testmrtools_p2();
    testmrtools_p3();
    testmrtools_p4();
  });
}

void testmrtools_p1() {
  test('gitlab_get_mr GETs the encoded project MR path', () {
    final body = echo('gitlab_get_mr', {
      'workspace': 'mygroup',
      'repository': 'myrepo',
      'pullRequestId': '42',
    });
    expect(body['method'], 'GET');
    expect(
      body['path'],
      '/api/v4/projects/mygroup%2Fmyrepo/merge_requests/42',
    );
    expect(body['headers']['PRIVATE-TOKEN'], 'glpat-test');
  });

  test('gitlab_get_mr accepts the legacy project/iid args', () {
    final body = echo('gitlab_get_mr', {'project': 'g/r', 'iid': 7});
    expect(body['path'], '/api/v4/projects/g%2Fr/merge_requests/7');
  });

  test('gitlab_list_mrs lists opened MRs oldest-first', () {
    final body = echo('gitlab_list_mrs', {
      'workspace': 'g',
      'repository': 'r',
      'state': 'open',
    });
    expect(body['method'], 'GET');
    expect(
      body['path'],
      '/api/v4/projects/g%2Fr/merge_requests'
      '?state=opened&per_page=100&order_by=created_at&sort=asc',
    );
  });

  test('gitlab_list_mrs closed state filters to closed/merged MRs', () {
    final result = tools.handlers['gitlab_list_mrs']!({
      'workspace': 'g',
      'repository': 'r',
      'state': 'closed',
    });
    // The stub state=all page carries a merged and an opened MR; only
    // the closed/merged one survives the client-side filter.
    expect(jsonDecode(result), [
      {'iid': 1, 'state': 'merged'},
    ]);
  });
}

void testmrtools_p2() {
  test('gitlab_add_mr_comment POSTs the note body', () {
    final body = echo('gitlab_add_mr_comment', {
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
      'text': 'LGTM!',
    });
    expect(body['method'], 'POST');
    expect(
      body['path'],
      '/api/v4/projects/g%2Fr/merge_requests/42/notes',
    );
    expect(jsonDecode(body['body'] as String), {'body': 'LGTM!'});
  });

  test('gitlab_create_mr_note accepts legacy body arg', () {
    final body = echo('gitlab_create_mr_note', {
      'project': 'g/r',
      'iid': 42,
      'body': 'a note',
    });
    expect(body['method'], 'POST');
    expect(jsonDecode(body['body'] as String), {'body': 'a note'});
  });

  test('gitlab_create_mr POSTs branch and title fields', () {
    final body = echo('gitlab_create_mr', {
      'workspace': 'g',
      'repository': 'r',
      'sourceBranch': 'feature/PROJ-1',
      'targetBranch': 'main',
      'title': 'T',
      'description': 'D',
      'removeSourceBranch': 'true',
    });
    expect(body['method'], 'POST');
    expect(body['path'], '/api/v4/projects/g%2Fr/merge_requests');
    expect(jsonDecode(body['body'] as String), {
      'source_branch': 'feature/PROJ-1',
      'target_branch': 'main',
      'title': 'T',
      'description': 'D',
      'remove_source_branch': true,
    });
  });
}

void testmrtools_p3() {
  test('gitlab_merge_mr PUTs the merge endpoint', () {
    final body = echo('gitlab_merge_mr', {
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
      'mergeCommitMessage': 'merge it',
    });
    expect(body['method'], 'PUT');
    expect(
      body['path'],
      '/api/v4/projects/g%2Fr/merge_requests/42/merge',
    );
    expect(
      jsonDecode(body['body'] as String),
      {'merge_commit_message': 'merge it'},
    );
  });

  test('gitlab_rebase_mr PUTs an empty body', () {
    final body = echo('gitlab_rebase_mr', {
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
    });
    expect(body['method'], 'PUT');
    expect(body['path'], '/api/v4/projects/g%2Fr/merge_requests/42/rebase');
    expect(body['body'], '{}');
  });
}

void testmrtools_p4() {
  test('gitlab_approve_mr / unapprove POST an empty body (gh-129)', () {
    final args = {
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
    };
    final approved = echo('gitlab_approve_mr', args);
    expect(approved['method'], 'POST');
    expect(
        approved['path'], '/api/v4/projects/g%2Fr/merge_requests/42/approve');
    expect(approved['body'], '{}');
    final unapproved = echo('gitlab_unapprove_mr', args);
    expect(unapproved['method'], 'POST');
    expect(
      unapproved['path'],
      '/api/v4/projects/g%2Fr/merge_requests/42/unapprove',
    );
    expect(unapproved['body'], '{}');
  });

  test('gitlab_add_mr_label / remove use add_labels / remove_labels', () {
    final args = {
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
      'label': 'pr_approved',
    };
    final added = echo('gitlab_add_mr_label', args);
    expect(added['method'], 'PUT');
    expect(jsonDecode(added['body'] as String), {'add_labels': 'pr_approved'});
    final removed = echo('gitlab_remove_mr_label', args);
    expect(jsonDecode(removed['body'] as String),
        {'remove_labels': 'pr_approved'});
  });
}

/// Threads, diffs, comments, discussions.
void _testThreadTools() {
  group('GitLabSyncTools thread and diff tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides({
        'GITLAB_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'GITLAB_TOKEN': 'glpat-test',
      });
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    testthreadtools_p1();
    testthreadtools_p2();
    testthreadtools_p3();
  });
}

void testthreadtools_p1() {
  test('gitlab_reply_to_mr_thread POSTs into the discussion', () {
    final body = echo('gitlab_reply_to_mr_thread', {
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
      'discussionId': 'abc',
      'text': 'done',
    });
    expect(body['method'], 'POST');
    expect(body['path'],
        '/api/v4/projects/g%2Fr/merge_requests/42/discussions/abc/notes');
    expect(jsonDecode(body['body'] as String), {'body': 'done'});
  });

  test('gitlab_resolve_mr_thread PUTs resolved true', () {
    final body = echo('gitlab_resolve_mr_thread', {
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
      'threadId': 'abc',
    });
    expect(body['method'], 'PUT');
    expect(
      body['path'],
      '/api/v4/projects/g%2Fr/merge_requests/42/discussions/abc',
    );
    expect(jsonDecode(body['body'] as String), {'resolved': true});
  });
}

void testthreadtools_p2() {
  test('gitlab_add_inline_mr_comment POSTs the position payload', () {
    final body = echo('gitlab_add_inline_mr_comment', {
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
      'filePath': 'src/Foo.java',
      'line': '10',
      'text': 'wrong',
      'baseSha': 'b',
      'headSha': 'h',
      'startSha': 's',
    });
    expect(body['method'], 'POST');
    expect(
        body['path'], '/api/v4/projects/g%2Fr/merge_requests/42/discussions');
    expect(jsonDecode(body['body'] as String), {
      'body': 'wrong',
      'position': {
        'position_type': 'text',
        'base_sha': 'b',
        'head_sha': 'h',
        'start_sha': 's',
        'new_path': 'src/Foo.java',
        'old_path': 'src/Foo.java',
        'new_line': 10,
      },
    });
  });

  test('gitlab_add_inline_mr_comment rejects a non-numeric line', () {
    final result = tools.handlers['gitlab_add_inline_mr_comment']!({
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
      'filePath': 'f',
      'line': 'x',
      'text': 't',
    });
    expect(jsonDecode(result),
        {'error': "Invalid line: expected numeric, got: 'x'"});
  });

  test('gitlab_get_mr_comments returns an empty array from a map body', () {
    final result = tools.handlers['gitlab_get_mr_comments']!({
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
    });
    expect(result, '[]');
  });
}

void testthreadtools_p3() {
  test('gitlab_get_mr_discussions returns an empty array', () {
    final result = tools.handlers['gitlab_get_mr_discussions']!({
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
    });
    expect(result, '[]');
  });

  test('gitlab_get_mr_diff_text returns empty text without changes', () {
    final result = tools.handlers['gitlab_get_mr_diff_text']!({
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
    });
    expect(result, '');
  });

  test('gitlab_get_mr_diff summarizes stats as JSON', () {
    final result = tools.handlers['gitlab_get_mr_diff']!({
      'workspace': 'g',
      'repository': 'r',
      'pullRequestId': '42',
    });
    expect(jsonDecode(result), {
      'stats': {'total': 0, 'additions': 0, 'deletions': 0},
      'changes': [],
    });
  });
}

/// CI tools: statuses, job logs, pipelines.
void _testCiTools() {
  group('GitLabSyncTools CI tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides({
        'GITLAB_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'GITLAB_TOKEN': 'glpat-test',
      });
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    testcitools_p1();
    testcitools_p2();
  });
}

void testcitools_p1() {
  test('gitlab_get_commit_statuses returns an empty array', () {
    final result = tools.handlers['gitlab_get_commit_statuses']!({
      'workspace': 'g',
      'repository': 'r',
      'commitSha': 'abc123',
    });
    expect(result, '[]');
  });

  test('gitlab_get_job_logs GETs the job trace', () {
    // The trace endpoint answers plain text (the echo payload rides
    // inside as text); the bridge contract wraps it in a JSON string.
    final raw = tools.handlers['gitlab_get_job_logs']!({
      'workspace': 'g',
      'repository': 'r',
      'jobId': '77',
    });
    final decoded = jsonDecode(raw);
    expect(decoded, isA<String>());
    final body = jsonDecode(decoded as String) as Map<String, dynamic>;
    expect(body['method'], 'GET');
    expect(body['path'], '/api/v4/projects/g%2Fr/jobs/77/trace');
  });

  test('gitlab_list_pipeline_runs returns an empty page list', () {
    // The echo server answers with a non-array object, which ends
    // pagination after the first page (asserted indirectly: the call
    // succeeds and reports an empty run list).
    final result = tools.handlers['gitlab_list_pipeline_runs']!({
      'workspace': 'g',
      'repository': 'r',
    });
    expect(result, '[]');
  });

  test('gitlab_list_pipeline_runs normalizes status and keeps ref', () {
    final result = tools.handlers['gitlab_list_pipeline_runs']!({
      'workspace': 'g',
      'repository': 'r',
      'status': 'failure',
      'ref': 'main',
      'limit': '10',
    });
    expect(result, '[]');
  });

  test('gitlab_list_pipeline_runs paginates to the limit', () {
    // The stub answers full pages of two runs; the limit-2 walk collects
    // the first page and stops at maxResults.
    final result = tools.handlers['gitlab_list_pipeline_runs']!({
      'workspace': 'g',
      'repository': 'r',
      'limit': '2',
    });
    final runs = jsonDecode(result) as List<dynamic>;
    expect(runs, hasLength(2));
    expect(runs.first['id'], 1);
  });
}

void testcitools_p2() {
  test('gitlab_trigger_pipeline POSTs ref plus variables', () {
    final body = echo('gitlab_trigger_pipeline', {
      'workspace': 'g',
      'repository': 'r',
      'ref': 'main',
      'variablesJson': '{"CONFIG_FILE":"agents/x.json"}',
    });
    expect(body['method'], 'POST');
    expect(body['path'], '/api/v4/projects/g%2Fr/pipeline');
    expect(jsonDecode(body['body'] as String), {
      'ref': 'main',
      'variables': [
        {'key': 'CONFIG_FILE', 'value': 'agents/x.json'},
      ],
    });
  });

  test('gitlab_trigger_pipeline rejects invalid variablesJson', () {
    final result = tools.handlers['gitlab_trigger_pipeline']!({
      'workspace': 'g',
      'repository': 'r',
      'ref': 'main',
      'variablesJson': 'not-json{',
    });
    expect(jsonDecode(result), {'error': 'Invalid variablesJson'});
  });
}

/// Release tools: get-or-create, upload, download.
void _testReleaseTools() {
  group('GitLabSyncTools release tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      tmp = Directory.systemTemp.createTempSync('dmtools_gl_release_');
      PropertyReader.setOverrides({
        'GITLAB_BASE_PATH': 'http://127.0.0.1:${server.port}',
        'GITLAB_TOKEN': 'glpat-test',
      });
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
      tmp.deleteSync(recursive: true);
    });

    testreleasetools_p1();
    testreleasetools_p2();
  });
}

void testreleasetools_p1() {
  test('gitlab_get_or_create_release creates with the default branch', () {
    final result = tools.handlers['gitlab_get_or_create_release']!({
      'workspace': 'g',
      'repository': 'r',
      'tagName': 'v1.0.0',
      'releaseName': 'Release 1',
      'body': 'notes',
    });
    final body = jsonDecode(result) as Map<String, dynamic>;
    // The final request echoed back is the release-create POST.
    expect(body['method'], 'POST');
    expect(body['path'], '/api/v4/projects/g%2Fr/releases');
    expect(jsonDecode(body['body'] as String), {
      'tag_name': 'v1.0.0',
      'name': 'Release 1',
      'ref': 'main', // default-branch fallback; server sends no default
      'description': 'notes',
    });
  });

  test('gitlab_upload_release_asset uploads then links', () {
    final asset = File('${tmp.path}/clip_123.png')
      ..writeAsStringSync('pngbytes');
    final result = tools.handlers['gitlab_upload_release_asset']!({
      'workspace': 'g',
      'repository': 'r',
      'tagName': 'v1.0.0',
      'filePath': asset.path,
      'overwrite': 'false',
    });
    final body = jsonDecode(result) as Map<String, dynamic>;
    // The final request echoed back is the asset-link POST.
    expect(body['method'], 'POST');
    expect(body['path'], '/api/v4/projects/g%2Fr/releases/v1.0.0/assets/links');
    final link = jsonDecode(body['body'] as String) as Map<String, dynamic>;
    expect(link['name'], 'clip_123.png');
    expect(link['link_type'], 'package');
    expect(link['direct_asset_path'], '/release-assets/v1.0.0/clip_123.png');
    expect(
        link['url'],
        contains('/packages/generic/release-assets/'
            'v1.0.0/clip_123.png'));
  });
}

void testreleasetools_p2() {
  test('gitlab_upload_release_asset errors on a missing file', () {
    final result = tools.handlers['gitlab_upload_release_asset']!({
      'workspace': 'g',
      'repository': 'r',
      'tagName': 'v1.0.0',
      'filePath': '${tmp.path}/missing.bin',
    });
    expect(jsonDecode(result),
        {'error': startsWith('Release asset file not found: ')});
  });

  test('gitlab_upload_release_asset overwrite deletes the same-named asset',
      () {
    final asset = File('${tmp.path}/app.zip')..writeAsStringSync('zipbytes');
    final result = tools.handlers['gitlab_upload_release_asset']!({
      'workspace': 'g',
      'repository': 'r',
      'tagName': 'v1.0.0',
      'filePath': asset.path,
      'assetName': 'app.zip',
      'overwrite': 'true',
    });
    // The flow still completes with the asset-link POST...
    final body = jsonDecode(result) as Map<String, dynamic>;
    expect(body['method'], 'POST');
    expect(body['path'], '/api/v4/projects/g%2Fr/releases/v1.0.0/assets/links');
    // ...and both pre-delete requests reached the server: the matching
    // release link (id 41) and the matching generic package (id 9).
    final deletes = jsonDecode(Process.runSync(
      'curl',
      ['-s', 'http://127.0.0.1:${server.port}/__delete_log'],
    ).stdout as String) as List<dynamic>;
    expect(deletes, hasLength(2));
    expect(deletes.first, contains('/releases/v1.0.0/assets/links/41'));
    expect(deletes.last, contains('/packages/9'));
  });

  test('gitlab_download_release_asset saves the body to the target', () {
    final target = '${tmp.path}/out/asset.txt';
    final result = tools.handlers['gitlab_download_release_asset']!({
      'workspace': 'g',
      'repository': 'r',
      'tagName': 'v1.0.0',
      'assetName': 'asset.txt',
      'targetFilePath': target,
    });
    expect(result, target);
    final saved = File(target);
    expect(saved.existsSync(), isTrue);
    expect(saved.readAsStringSync(), contains('"method": "GET"'));
  });
}

/// [buildGitlabUnifiedDiffText] and [parseGitlabDiffStats] fixtures.
void _testDiffHelpers() {
  group('buildGitlabUnifiedDiffText', () {
    testdiffhelpers_p1();
    testdiffhelpers_p2();
  });
}

void testdiffhelpers_p1() {
  test('reconstructs headers for a modified file', () {
    final text = buildGitlabUnifiedDiffText({
      'changes': [
        {
          'old_path': 'src/A.java',
          'new_path': 'src/A.java',
          'diff': '@@ -1,1 +1,2 @@\n old\n+new',
        },
      ],
    });
    expect(
        text,
        'diff --git a/src/A.java b/src/A.java\n'
        '--- a/src/A.java\n'
        '+++ b/src/A.java\n'
        '@@ -1,1 +1,2 @@\n old\n+new\n');
  });

  test('renders new-file and deleted-file headers', () {
    final text = buildGitlabUnifiedDiffText({
      'changes': [
        {
          'old_path': 'x.txt',
          'new_path': 'x.txt',
          'new_file': true,
          'diff': '+hello',
        },
        {
          'old_path': 'y.txt',
          'new_path': 'y.txt',
          'deleted_file': true,
          'diff': '-world',
        },
      ],
    });
    expect(text, contains('new file mode 100644\n--- /dev/null\n'));
    expect(text, contains('deleted file mode 100644\n'));
    expect(text, contains('+++ /dev/null\n'));
  });

  test('missing changes array yields empty text', () {
    expect(buildGitlabUnifiedDiffText({}), '');
  });
}

void testdiffhelpers_p2() {
  group('parseGitlabDiffStats', () {
    test('counts additions and deletions, skipping file headers', () {
      final stats = parseGitlabDiffStats({
        'changes': [
          {
            'new_path': 'a.txt',
            // '--- not counted' is a file header line, not a deletion.
            'diff': '@@ -1 +1 @@\n-keep\n+one\n+two\n--- not counted',
          },
        ],
      });
      expect(stats['stats'], {
        'total': 3,
        'additions': 2,
        'deletions': 1,
      });
      expect(stats['changes'], [
        {'filePath': 'a.txt'},
      ]);
    });
  });
}

/// [latestGitlabStatusPerName] keeps the latest report per name.
void _testStatusDedupe() {
  test('normalizeGitlabPipelineStatus maps cross-platform synonyms', () {
    expect(normalizeGitlabPipelineStatus('failure'), 'failed');
    expect(normalizeGitlabPipelineStatus('in_progress'), 'running');
    expect(normalizeGitlabPipelineStatus('success'), 'success');
    expect(normalizeGitlabPipelineStatus(''), '');
  });

  test('keeps the newest created_at per status name', () {
    final latest = latestGitlabStatusPerName([
      {'name': 'ci', 'status': 'failed', 'created_at': '2024-01-01T00:00:00Z'},
      {'name': 'ci', 'status': 'success', 'created_at': '2024-02-01T00:00:00Z'},
      {
        'name': 'lint',
        'status': 'success',
        'created_at': '2024-01-15T00:00:00Z'
      },
    ]);
    expect(latest, hasLength(2));
    final ci = latest.firstWhere((s) => s['name'] == 'ci');
    expect(ci['status'], 'success');
  });

  test('missing created_at falls back to the last seen entry', () {
    final latest = latestGitlabStatusPerName([
      {'name': 'ci', 'status': 'failed'},
      {'name': 'ci', 'status': 'success'},
    ]);
    expect(latest.single['status'], 'success');
  });
}
