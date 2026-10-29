import 'dart:convert';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/sync_tools/ado_sync_tools.dart';
import 'package:test/test.dart';

import '../echo_server_helper.dart';

/// Shared fixtures for the echo-server-backed groups (each group's
/// setUp rebinds the server; tools is stateless).
late EchoServer server;
const tools = AdoSyncTools();

Map<String, dynamic> echo(String tool, Map<String, dynamic> args) =>
    jsonDecode(tools.handlers[tool]!(args)) as Map<String, dynamic>;

/// Tests for [AdoSyncTools].
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
    _testWorkItemTools();
    _testWorkItemLabelTools();
    _testWorkItemLabelEdgeTools();
    _testPrReadTools();
    _testPrWriteTools();
    _testPipelineTools();
  }
  _testThreadStatusMapping();
}

/// Every tool name the agent scripts (js/common/scm.js ado provider) call
/// must resolve to a handler.
void _testHandlerSurface() {
  test('AdoSyncTools.handlers covers the agent tool surface', () {
    const tools = AdoSyncTools();
    final names = [
      'ado_get_work_item',
      'ado_add_work_item_comment',
      'ado_get_work_item_comments',
      'ado_move_to_state',
      'ado_assign_work_item',
      'ado_create_work_item',
      'ado_link_work_items',
      'ado_update_description',
      'ado_update_tags',
      'ado_update_field',
      'ado_set_priority',
      'ado_get_field_code',
      'ado_attach_file',
      'ado_list_work_items',
      'ado_list_prs',
      'ado_get_pr',
      'ado_get_pr_comments',
      'ado_add_pr_comment',
      'ado_reply_to_pr_thread',
      'ado_resolve_pr_thread',
      'ado_add_inline_comment',
      'ado_merge_pr',
      'ado_add_pr_label',
      'ado_remove_pr_label',
      'ado_get_pr_diff',
      'ado_list_pipelines',
      'ado_list_pipeline_runs',
      'ado_trigger_pipeline',
      'ado_get_pipeline_logs',
    ];
    for (final name in names) {
      expect(tools.handlers, containsPair(name, anything),
          reason: 'missing handler for $name');
    }
  });
}

/// Unconfigured ADO reports a JSON error, not a crash.
void _testNoConfig() {
  test('tools return config error without ADO config', () {
    PropertyReader.setOverrides({
      'ADO_ORGANIZATION': '',
      'ADO_PROJECT': '',
      'ADO_PAT_TOKEN': '',
    });
    final result = const AdoSyncTools()
        .handlers['ado_get_pr']!({'repository': 'r', 'pullRequestId': '1'});
    expect(jsonDecode(result), {'error': 'ADO not configured'});
    PropertyReader.clearOverrides();
  });
}

/// Work-item tools moved from the dispatcher's inline section.
void _testWorkItemTools() {
  group('AdoSyncTools work item tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides(adoOverrides(server.port));
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    test('ado_get_work_item GETs the work item', () {
      final body = echo('ado_get_work_item', {'id': 7});
      expect(body['method'], 'GET');
      expect(
        body['path'],
        '/org/proj/_apis/wit/workitems/7?api-version=7.0',
      );
      expect(
        body['headers']['Authorization'],
        'Basic ${base64Encode(utf8.encode(':pat-token'))}',
      );
    });

    test('ado_list_work_items passes an ADO error body through unchanged', () {
      final result = tools.handlers['ado_list_work_items']!({
        'wiql': 'dt-wiql-error',
      });
      // An error envelope must not look like an empty query result.
      expect(jsonDecode(result), {
        'message': 'TF51005: query is invalid',
        'method': 'POST',
        'path': isA<String>(),
        'headers': isA<Map<String, dynamic>>(),
        'body': isA<String>(),
      });
    });

    test('ado_list_work_items re-fetches the WIQL stub ids', () {
      final result = tools.handlers['ado_list_work_items']!({
        'wiql': 'SELECT [System.Id] FROM WorkItems',
      });
      // The echo server answers the WIQL POST with a {workItems:[{id:7}]}
      // stub and the ids= detail GET with a full item fixture.
      expect(jsonDecode(result), [
        {
          'id': 7,
          'fields': {'System.Title': 'T'},
        },
      ]);
    });
  });
}

/// PR read tools: get/list/comments/diff.
void _testPrReadTools() {
  group('AdoSyncTools PR read tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides(adoOverrides(server.port));
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    test('ado_get_pr GETs the repository-scoped PR', () {
      final body =
          echo('ado_get_pr', {'repository': 'repo', 'pullRequestId': '5'});
      expect(body['method'], 'GET');
      expect(
        body['path'],
        '/org/proj/_apis/git/repositories/repo/pullrequests/5'
        '?api-version=7.0',
      );
    });

    test('ado_list_prs normalizes open to active', () {
      final body =
          echo('ado_list_prs', {'repository': 'repo', 'status': 'open'});
      expect(
        body['path'],
        '/org/proj/_apis/git/repositories/repo/pullrequests'
        '?searchCriteria.status=active&api-version=7.0',
      );
    });

    test('ado_list_prs normalizes merged to completed', () {
      final body =
          echo('ado_list_prs', {'repository': 'repo', 'status': 'merged'});
      expect(body['path'], contains('searchCriteria.status=completed'));
    });

    test('ado_get_pr_comments GETs the threads', () {
      final body = echo('ado_get_pr_comments', {
        'repository': 'repo',
        'pullRequestId': '5',
      });
      expect(
          body['path'],
          '/org/proj/_apis/git/repositories/repo/pullrequests/5/threads'
          '?api-version=7.0');
    });

    test('ado_get_pr_diff returns empty changes without iterations', () {
      final result = tools.handlers['ado_get_pr_diff']!({
        'repository': 'repo',
        'pullRequestId': '5',
      });
      expect(jsonDecode(result), {'changes': []});
    });
  });
}

/// PR write tools: comments, replies, resolve, inline, merge, labels.
void _testPrWriteTools() {
  group('AdoSyncTools PR write tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides(adoOverrides(server.port));
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    testprwritetools_p1();
    testprwritetools_p2();
    testprwritetools_p3();
    testprwritetools_p4();
  });
}

void testprwritetools_p1() {
  test('ado_add_pr_comment POSTs a new active thread', () {
    final body = echo('ado_add_pr_comment', {
      'repository': 'repo',
      'pullRequestId': '5',
      'text': 'Looks good!',
    });
    expect(body['method'], 'POST');
    expect(jsonDecode(body['body'] as String), {
      'comments': [
        {'parentCommentId': 0, 'content': 'Looks good!', 'commentType': 1},
      ],
      'status': 1,
    });
  });

  test('ado_reply_to_pr_thread POSTs a reply with parentCommentId 1', () {
    final body = echo('ado_reply_to_pr_thread', {
      'repository': 'repo',
      'pullRequestId': '5',
      'threadId': '9',
      'text': 'Fixed.',
    });
    expect(
      body['path'],
      '/org/proj/_apis/git/repositories/repo/pullrequests/5/threads/9/'
      'comments?api-version=7.0',
    );
    expect(jsonDecode(body['body'] as String), {
      'content': 'Fixed.',
      'parentCommentId': 1,
      'commentType': 1,
    });
  });

  test('ado_resolve_pr_thread PATCHes the numeric status', () {
    final body = echo('ado_resolve_pr_thread', {
      'repository': 'repo',
      'pullRequestId': '5',
      'threadId': '9',
    });
    expect(body['method'], 'PATCH');
    expect(jsonDecode(body['body'] as String), {'status': 2});
  });
}

void testprwritetools_p2() {
  test('ado_add_inline_comment POSTs a right-side threadContext', () {
    final body = echo('ado_add_inline_comment', {
      'repository': 'repo',
      'pullRequestId': '5',
      'filePath': 'src/Foo.java',
      'line': '42',
      'text': 'refactor this',
    });
    expect(body['method'], 'POST');
    final thread = jsonDecode(body['body'] as String) as Map<String, dynamic>;
    expect(thread['threadContext'], {
      'filePath': '/src/Foo.java',
      'rightFileStart': {'line': 42, 'offset': 1},
      'rightFileEnd': {'line': 42, 'offset': 1},
    });
    expect(thread['status'], 1);
  });

  test('ado_add_inline_comment supports left side and startLine', () {
    final body = echo('ado_add_inline_comment', {
      'repository': 'repo',
      'pullRequestId': '5',
      'path': '/src/Bar.java',
      'line': '20',
      'startLine': '10',
      'side': 'left',
      'text': 'old code',
    });
    final thread = jsonDecode(body['body'] as String) as Map<String, dynamic>;
    expect(thread['threadContext'], {
      'filePath': '/src/Bar.java',
      'leftFileStart': {'line': 10, 'offset': 1},
      'leftFileEnd': {'line': 20, 'offset': 1},
    });
  });

  test('ado_add_inline_comment rejects a non-numeric line', () {
    final result = tools.handlers['ado_add_inline_comment']!({
      'repository': 'repo',
      'pullRequestId': '5',
      'filePath': 'f',
      'line': 'x',
      'text': 't',
    });
    expect(jsonDecode(result), {
      'error': "Invalid line: expected a numeric line number, but got: 'x'",
    });
  });
}

void testprwritetools_p3() {
  test('ado_merge_pr PATCHes completion with squash defaults', () {
    final body = echo('ado_merge_pr', {
      'repository': 'repo',
      'pullRequestId': '5',
    });
    expect(body['method'], 'PATCH');
    expect(
      body['path'],
      '/org/proj/_apis/git/repositories/repo/pullrequests/5'
      '?api-version=7.0',
    );
    expect(jsonDecode(body['body'] as String), {
      'status': 'completed',
      'completionOptions': {
        'mergeStrategy': 'squash',
        'deleteSourceBranch': true,
      },
    });
  });

  test('ado_merge_pr honors explicit options', () {
    final body = echo('ado_merge_pr', {
      'repository': 'repo',
      'pullRequestId': '5',
      'mergeStrategy': 'rebase',
      'deleteSourceBranch': 'false',
      'commitMessage': 'merge!',
    });
    expect(jsonDecode(body['body'] as String), {
      'status': 'completed',
      'completionOptions': {
        'mergeStrategy': 'rebase',
        'deleteSourceBranch': false,
        'mergeCommitMessage': 'merge!',
      },
    });
  });

  test('ado_add_pr_label POSTs the preview API', () {
    final body = echo('ado_add_pr_label', {
      'repository': 'repo',
      'pullRequestId': '5',
      'label': 'needs-review',
    });
    expect(
      body['path'],
      '/org/proj/_apis/git/repositories/repo/pullrequests/5/labels'
      '?api-version=7.0-preview.1',
    );
    expect(jsonDecode(body['body'] as String), {'name': 'needs-review'});
  });
}

void testprwritetools_p4() {
  test('ado_remove_pr_label DELETEs by label id', () {
    final body = echo('ado_remove_pr_label', {
      'repository': 'repo',
      'pullRequestId': '5',
      'labelId': 'e10671ab',
    });
    expect(body['method'], 'DELETE');
    expect(
      body['path'],
      '/org/proj/_apis/git/repositories/repo/pullrequests/5/labels/'
      'e10671ab?api-version=7.0-preview.1',
    );
  });
}

/// Pipeline tools: list, runs, trigger, logs.
void _testPipelineTools() {
  group('AdoSyncTools pipeline tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides(adoOverrides(server.port));
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    testpipelinetools_p1();
    testpipelinetools_p2();
  });
}

void testpipelinetools_p1() {
  test('ado_list_pipelines GETs the project pipelines', () {
    final body = echo('ado_list_pipelines', {});
    expect(body['path'], '/org/proj/_apis/pipelines?api-version=7.0');
  });

  test('ado_list_pipeline_runs defaults \$top to 10', () {
    final body = echo('ado_list_pipeline_runs', {'pipelineId': 3});
    expect(
      body['path'],
      '/org/proj/_apis/pipelines/3/runs?\$top=10&api-version=7.0',
    );
  });

  test('ado_list_pipeline_runs honors top', () {
    final body = echo('ado_list_pipeline_runs', {'pipelineId': 3, 'top': 5});
    expect(body['path'], contains('\$top=5'));
  });

  test('ado_trigger_pipeline POSTs ref and variables', () {
    final body = echo('ado_trigger_pipeline', {
      'pipelineId': 3,
      'branch': 'feature/x',
      'variables': '{"CONFIG_FILE":"agents/x.json"}',
    });
    expect(body['method'], 'POST');
    expect(
        body['path'],
        '/org/proj/_apis/pipelines/3/runs'
        '?api-version=7.0');
    expect(jsonDecode(body['body'] as String), {
      'resources': {
        'repositories': {
          'self': {'refName': 'refs/heads/feature/x'},
        },
      },
      'variables': {
        'CONFIG_FILE': {'value': 'agents/x.json', 'isSecret': false},
      },
    });
  });

  test('ado_trigger_pipeline rejects invalid variables JSON', () {
    final result = tools.handlers['ado_trigger_pipeline']!({
      'pipelineId': 3,
      'variables': 'nope{',
    });
    expect(jsonDecode(result), {'error': 'Invalid variables'});
  });

  test('ado_get_pipeline_logs reports missing timeline records', () {
    final result = tools.handlers['ado_get_pipeline_logs']!({'buildId': 8});
    expect(jsonDecode(result), '(no timeline records found for build 8)');
  });
}

void testpipelinetools_p2() {
  test('ado_get_pipeline_logs collects and tails task logs', () {
    final result = tools
        .handlers['ado_get_pipeline_logs']!({'buildId': 12, 'tailLines': 2});
    // The Stage record is skipped, the logless Test task is skipped, and
    // only the last 2 of the 3 stub log lines survive the tail.
    expect(
        jsonDecode(result), '=== Task: Build ===\nlog-line-2\nlog-line-3\n\n');
  });

  test('ado_get_pipeline_logs accepts a string tailLines', () {
    final result = tools
        .handlers['ado_get_pipeline_logs']!({'buildId': 12, 'tailLines': '1'});
    expect(jsonDecode(result), '=== Task: Build ===\nlog-line-3\n\n');
  });

  test('ado_get_pipeline_logs keeps everything with tailLines 0', () {
    final result = tools
        .handlers['ado_get_pipeline_logs']!({'buildId': 12, 'tailLines': 0});
    expect(jsonDecode(result),
        '=== Task: Build ===\nlog-line-1\nlog-line-2\nlog-line-3\n\n');
  });

  test('ado_get_pipeline_logs filters records by taskName', () {
    final result = tools.handlers['ado_get_pipeline_logs']!(
        {'buildId': 12, 'taskName': 'Test'});
    // The only Test task carries no log id, so nothing is collected.
    expect(jsonDecode(result), '(no logs found for build 12)');
  });

  test('ado_list_pipeline_runs coerces a numeric top', () {
    final body = echo('ado_list_pipeline_runs', {'pipelineId': 3, 'top': 2.5});
    expect(body['path'], contains('\$top=2'));
  });
}

/// [mapAdoThreadStatus] name → numeric code mapping.
void _testThreadStatusMapping() {
  test('maps status names to ADO numeric codes', () {
    expect(mapAdoThreadStatus('active'), 1);
    expect(mapAdoThreadStatus('fixed'), 2);
    expect(mapAdoThreadStatus('resolved'), 2);
    expect(mapAdoThreadStatus('wontFix'), 3);
    expect(mapAdoThreadStatus('wont_fix'), 3);
    expect(mapAdoThreadStatus('closed'), 4);
    expect(mapAdoThreadStatus('byDesign'), 5);
    expect(mapAdoThreadStatus('pending'), 6);
    expect(mapAdoThreadStatus('anything-else'), 2);
  });
}

/// Standard ADO overrides pointing at the echo [port].
Map<String, String> adoOverrides(int port) => {
      'ADO_BASE_PATH': 'http://127.0.0.1:$port',
      'ADO_ORGANIZATION': 'org',
      'ADO_PROJECT': 'proj',
      'ADO_PAT_TOKEN': 'pat-token',
    };

/// Work-item single-label tools (dm.ai #577): add/remove keep the other
/// tags; the PATCH reaching the echo server asserts the tag set.
void _testWorkItemLabelTools() {
  group('AdoSyncTools work item label tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides(adoOverrides(server.port));
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    test('ado_add_work_item_label PATCHes the merged tag set', () {
      final body =
          echo('ado_add_work_item_label', {'id': 9, 'label': 'urgent'});
      expect(body['method'], 'PATCH');
      expect(
        body['path'],
        '/org/proj/_apis/wit/workitems/9?api-version=7.0',
      );
      expect(
        body['headers']['Content-Type'],
        'application/json-patch+json',
      );
      final patch = jsonDecode(body['body'] as String) as List;
      expect(patch, [
        {
          'op': 'add',
          'path': '/fields/System.Tags',
          'value': 'existing; ai_generated; urgent',
        }
      ]);
    });

    test('ado_remove_work_item_label PATCHes the remaining tag set', () {
      final body = echo(
          'ado_remove_work_item_label', {'id': 9, 'label': 'ai_generated'});
      expect(body['method'], 'PATCH');
      final patch = jsonDecode(body['body'] as String) as List;
      expect(patch, [
        {
          'op': 'add',
          'path': '/fields/System.Tags',
          'value': 'existing',
        }
      ]);
    });
  });
}

/// Label-tool edge cases (dm.ai #577): the idempotent no-op and the
/// missing-label guard — no PATCH is sent in either case.
void _testWorkItemLabelEdgeTools() {
  group('AdoSyncTools work item label edges', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides(adoOverrides(server.port));
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    test('ado_add_work_item_label is a no-op when the label exists', () {
      final result = tools.handlers['ado_add_work_item_label']!(
          {'id': 9, 'label': 'AI_GENERATED'});
      expect(jsonDecode(result), {'success': true});
    });

    test('ado_remove_work_item_label requires a label', () {
      final result = tools.handlers['ado_remove_work_item_label']!({'id': 9});
      expect(jsonDecode(result), containsPair('error', 'label is required'));
    });
  });
}
