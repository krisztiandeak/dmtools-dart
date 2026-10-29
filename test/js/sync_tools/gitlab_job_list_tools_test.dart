import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/sync_http_bridge.dart';
import 'package:dmtools/src/js/sync_tools/gitlab_sync_tools.dart';
import 'package:test/test.dart';

import '../echo_server_helper.dart';

/// gh-380 job-listing tools: `gitlab_list_project_jobs` (project +
/// pipeline scope, client-side exact-name filter, scope[]/per_page/page
/// params) and the `gitlab_get_pipeline(s)` catalog-coherence closures.
///
/// Split from gitlab_sync_tools_test.dart for the crap4dart file-size
/// gate. Server-dependent groups start a Python echo server subprocess
/// (Dart's [HttpServer] runs on the event loop, which is frozen during
/// `Process.runSync('curl', …)`); request shapes are read back from the
/// server's full log because the job-list handlers return the fixture
/// body, not the request echo.
late EchoServer server;
const tools = GitLabSyncTools();

/// Every request the echo server has served so far (`{method, path,
/// body, headers}` each).
Future<List<Map<String, dynamic>>> requestLog() async {
  final client = HttpClient();
  try {
    final request = await client.get('127.0.0.1', server.port, '/__full_log');
    final response = await request.close();
    final log =
        jsonDecode(await utf8.decoder.bind(response).join()) as List<dynamic>;
    return [for (final entry in log) entry as Map<String, dynamic>];
  } finally {
    client.close();
  }
}

void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });
  if (hasPython3()) {
    _testJobListTools();
  }
}

void _testJobListTools() {
  group('GitLabSyncTools job listing tools', () {
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

    testjoblisttools_p1();
    testjoblisttools_p2();
    testjoblisttools_p3();
    testjoblisttools_p4();
    testjoblisttools_p5();
  });
}

void testjoblisttools_p1() {
  test('gitlab_list_project_jobs GETs the project jobs, newest first',
      () async {
    final result = tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
    });
    final jobs = jsonDecode(result) as List<dynamic>;
    expect(jobs.map((j) => j['id']), [101, 102]);
    final requests = await requestLog();
    expect(requests.single['method'], 'GET');
    expect(requests.single['path'],
        '/api/v4/projects/g%2Fr/jobs?per_page=20&page=1');
  });

  test(
      'gitlab_list_project_jobs honors per_page and page (max 100 '
      'clamp)', () async {
    tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'per_page': '250',
      'page': '3',
    });
    final requests = await requestLog();
    expect(requests.single['path'],
        '/api/v4/projects/g%2Fr/jobs?per_page=100&page=3');
  });

  test('gitlab_list_project_jobs accepts the camelCase perPage spelling',
      () async {
    tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'perPage': '50',
    });
    final requests = await requestLog();
    expect(requests.single['path'],
        '/api/v4/projects/g%2Fr/jobs?per_page=50&page=1');
  });
}

void testjoblisttools_p2() {
  test('gitlab_list_project_jobs maps scope to repeated scope[] params',
      () async {
    tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'scope': 'success',
    });
    tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'scope': ['success', 'running'],
    });
    tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'scope': 'success,running',
    });
    final paths = (await requestLog()).map((r) => r['path']).toList();
    expect(paths[0], contains('scope%5B%5D=success'));
    expect(paths[0], isNot(contains('scope%5B%5D=running')));
    expect(paths[1], contains('scope%5B%5D=success'));
    expect(paths[1], contains('scope%5B%5D=running'));
    expect(paths[2], contains('scope%5B%5D=success'));
    expect(paths[2], contains('scope%5B%5D=running'));
  });

  test(
      'gitlab_list_project_jobs scopes to the pipeline when '
      'pipelineId is given', () async {
    final result = tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'pipelineId': '9',
    });
    final jobs = jsonDecode(result) as List<dynamic>;
    expect(jobs.single['id'], 501);
    expect(jobs.single['pipeline'], {'id': 9});
    final requests = await requestLog();
    expect(requests.single['path'],
        '/api/v4/projects/g%2Fr/pipelines/9/jobs?per_page=20&page=1');
  });
}

void testjoblisttools_p3() {
  test('name narrows the result to exact matches', () {
    final result = tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'name': 'ai-teammate',
    });
    final jobs = jsonDecode(result) as List<dynamic>;
    expect(jobs.map((j) => j['id']), [101]);
  });

  test('a name with no matches returns an empty list, not an error', () {
    final result = tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'name': 'no-such-job',
    });
    expect(result, '[]');
  });

  test('the name filter does not match partial names', () {
    final result = tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'name': 'ai',
    });
    expect(result, '[]');
  });

  test('the name filter passes a non-array body through verbatim', () {
    // Pipeline 5 has no fixture: the echo server answers the request
    // object, which the filter must not touch.
    final result = tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'pipelineId': '5',
      'name': 'ai-teammate',
    });
    final body = jsonDecode(result) as Map<String, dynamic>;
    expect(body['method'], 'GET');
    expect(body['path'], contains('/pipelines/5/jobs?'));
  });
}

void testjoblisttools_p5() {
  test('scope[] params are wire-identical on both HTTP transports', () async {
    // Transport-parity regression (gh-380 rework): the curl fallback
    // sends the URL verbatim while the pooled-isolate bridge routes it
    // through Uri.parse/HttpClient, which percent-encodes '[' and ']'.
    // Which transport serves a request is a boot-timing race, so the
    // tool must pre-encode the brackets — both transports must emit the
    // same bytes.
    SyncHttpBridge.shared.dispose();
    tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'scope': 'success,running',
    });
    final curlPaths = (await requestLog()).map((r) => r['path']).toList();
    expect(curlPaths.single, contains('scope%5B%5D=success'));
    expect(curlPaths.single, contains('scope%5B%5D=running'));

    await SyncHttpBridge.shared.boot();
    addTearDown(SyncHttpBridge.shared.dispose);
    tools.handlers['gitlab_list_project_jobs']!({
      'workspace': 'g',
      'repository': 'r',
      'scope': 'success,running',
    });
    final paths = (await requestLog()).map((r) => r['path']).toList();
    expect(paths.last, contains('scope%5B%5D=success'));
    expect(paths.last, contains('scope%5B%5D=running'));
  });
}

void testjoblisttools_p4() {
  test('gitlab_get_pipelines GETs the project pipelines', () {
    final body = jsonDecode(tools.handlers['gitlab_get_pipelines']!({
      'workspace': 'g',
      'repository': 'r',
    })) as Map<String, dynamic>;
    expect(body['method'], 'GET');
    expect(body['path'], '/api/v4/projects/g%2Fr/pipelines');
  });

  test('gitlab_get_pipeline GETs one pipeline by id', () {
    final body = jsonDecode(tools.handlers['gitlab_get_pipeline']!({
      'workspace': 'g',
      'repository': 'r',
      'pipeline_id': '7',
    })) as Map<String, dynamic>;
    expect(body['method'], 'GET');
    expect(body['path'], '/api/v4/projects/g%2Fr/pipelines/7');
  });

  test('gitlab_get_pipeline accepts the pipelineId spelling', () {
    final body = jsonDecode(tools.handlers['gitlab_get_pipeline']!({
      'workspace': 'g',
      'repository': 'r',
      'pipelineId': '7',
    })) as Map<String, dynamic>;
    expect(body['path'], '/api/v4/projects/g%2Fr/pipelines/7');
  });
}
