import 'dart:convert';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/sync_tools/jira_sync_tools.dart';
import 'package:dmtools/src/js/sync_tools/tracker_gitlab_router.dart';
import 'package:test/test.dart';

import '../echo_server_helper.dart';
import 'github_fixture_helper.dart';

/// Tests for [TrackerGitLabRouter] — the gh-N → GitLab Issues routing of
/// tracker-shaped `jira_*` calls when `DEFAULT_TRACKER=gitlab` and Jira is
/// unconfigured. HTTP runs against `gitlab_issues_fixture_server.py`.
void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });
  group('TrackerGitLabRouter opt-in', _optInTests);
  if (hasPython3()) {
    group('TrackerGitLabRouter read tools (fixture)', _readTests);
    group('TrackerGitLabRouter write tools (fixture)', _writeTests);
    group('TrackerGitLabRouter search (fixture)', _searchTests);
  }
}

String _errOf(String result) =>
    (jsonDecode(result) as Map<String, dynamic>)['error'] as String;

const _router = TrackerGitLabRouter();

/// Routing decision tests — no HTTP.
void _optInTests() {
  tearDown(PropertyReader.clearOverrides);

  test('DEFAULT_TRACKER unset falls through', () {
    PropertyReader.setOverrides(const {});
    expect(_router.maybeRoute('jira_add_label', {'key': 'gh-4', 'label': 'x'}),
        isNull);
  });

  test('DEFAULT_TRACKER=github falls through', () {
    PropertyReader.setOverrides(const {'DEFAULT_TRACKER': 'github'});
    expect(_router.maybeRoute('jira_add_label', {'key': 'gh-4', 'label': 'x'}),
        isNull);
  });

  test('non-gh key falls through', () {
    PropertyReader.setOverrides(const {'DEFAULT_TRACKER': 'gitlab'});
    expect(_router.maybeRoute('jira_add_label', {'key': 'PROJ-1'}), isNull);
  });

  test('a configured Jira keeps the Jira path', () {
    PropertyReader.setOverrides(const {
      'DEFAULT_TRACKER': 'gitlab',
      'JIRA_BASE_PATH': 'https://jira.example.com',
      'JIRA_LOGIN_PASS_TOKEN': 'token',
    });
    expect(_router.maybeRoute('jira_add_label', {'key': 'gh-4', 'label': 'x'}),
        isNull);
  });

  test('routes and names the missing GitLab config', () {
    PropertyReader.setOverrides(const {'DEFAULT_TRACKER': 'gitlab'});
    final result = _router.maybeRoute('jira_get_ticket', {'key': 'gh-4'})!;
    expect(_errOf(result), contains('GITLAB_BASE_PATH'));
  });

  test('names a malformed tracker project', () {
    PropertyReader.setOverrides(const {
      'DEFAULT_TRACKER': 'gitlab',
      'GITLAB_BASE_PATH': 'https://gitlab.example.com',
      'GITLAB_TOKEN': 'glpat-test',
      'DMTOOLS_TRACKER_REPO': 'no-slash',
    });
    final result = _router.maybeRoute('jira_get_ticket', {'key': 'gh-4'})!;
    expect(_errOf(result), contains('not configured or malformed'));
  });
}

/// Harness: starts the GitLab fixture and points the env at it.
class _Fixture {
  late GithubFixtureServer server;
  final tools = const JiraSyncTools();

  Future<void> start() async {
    server = GithubFixtureServer();
    await server.start(script: 'gitlab_issues_fixture_server.py');
    PropertyReader.setOverrides({
      'DEFAULT_TRACKER': 'gitlab',
      'GITLAB_BASE_PATH': 'http://127.0.0.1:${server.port}',
      'GITLAB_TOKEN': 'glpat-test',
      'DMTOOLS_TRACKER_REPO': 'o/r',
    });
  }

  void stop() {
    PropertyReader.clearOverrides();
    server.stop();
  }

  Map<String, dynamic> get lastRequest =>
      jsonDecode(server.lastRequestJson!) as Map<String, dynamic>;

  Map<String, dynamic> get lastBody =>
      jsonDecode(lastRequest['body'] as String) as Map<String, dynamic>;
}

void _readTests() {
  final fx = _Fixture();
  setUp(fx.start);
  tearDown(fx.stop);

  test('jira_get_ticket maps the issue to the Jira shape', () {
    final ticket =
        jsonDecode(fx.tools.dispatch('jira_get_ticket', {'key': 'gh-4'}))
            as Map;
    final fields = ticket['fields'] as Map;
    expect(ticket['key'], 'gh-4');
    expect(fields['summary'], 'Smoke test');
    expect(fields['description'], 'issue body text');
    expect(fields['labels'], ['agent:dev', 'status:In Progress']);
    expect((fields['status'] as Map)['name'], 'In Progress');
    expect(fx.lastRequest['token'], 'glpat-test');
  });

  test('a closed issue without a status label reads as Done', () {
    final ticket =
        jsonDecode(fx.tools.dispatch('jira_get_ticket', {'key': 'gh-5'}))
            as Map;
    expect((ticket['fields'] as Map)['status'], {'name': 'Done'});
  });

  test('jira_get_comments returns user notes only', () {
    final comments =
        (jsonDecode(fx.tools.dispatch('jira_get_comments', {'key': 'gh-4'}))
            as Map)['comments'] as List;
    expect(comments, hasLength(1));
    expect((comments.first as Map)['body'], 'first');
    expect(((comments.first as Map)['author'] as Map)['displayName'], 'kdeak');
  });

  test('a missing issue surfaces an error envelope', () {
    expect(_errOf(fx.tools.dispatch('jira_get_ticket', {'key': 'gh-99'})),
        contains('404'));
  });
}

void _writeTests() {
  final fx = _Fixture();
  setUp(fx.start);
  tearDown(fx.stop);

  test('jira_post_comment POSTs a note with Markdown', () {
    fx.tools
        .dispatch('jira_post_comment', {'key': 'gh-4', 'comment': 'h3. Title'});
    expect(fx.lastRequest['method'], 'POST');
    expect(fx.lastRequest['path'], '/api/v4/projects/o%2Fr/issues/4/notes');
    expect(fx.lastBody['body'], contains('### Title'));
  });

  test('jira_add_label PUTs add_labels', () {
    fx.tools
        .dispatch('jira_add_label', {'key': 'gh-4', 'label': 'pr_approved'});
    expect(fx.lastRequest['method'], 'PUT');
    expect(fx.lastRequest['path'], '/api/v4/projects/o%2Fr/issues/4');
    expect(fx.lastBody, {'add_labels': 'pr_approved'});
  });

  test('jira_remove_label PUTs remove_labels', () {
    fx.tools
        .dispatch('jira_remove_label', {'key': 'gh-4', 'label': 'agent:dev'});
    expect(fx.lastBody, {'remove_labels': 'agent:dev'});
  });

  test('jira_move_to_status swaps the status label and closes on Done', () {
    fx.tools
        .dispatch('jira_move_to_status', {'key': 'gh-4', 'statusName': 'Done'});
    expect(fx.lastBody, {
      'add_labels': 'status:Done',
      'remove_labels': 'status:In Progress',
      'state_event': 'close',
    });
  });

  test('jira_move_to_status reopens a closed issue on an Open-ish status', () {
    fx.tools.dispatch(
        'jira_move_to_status', {'key': 'gh-5', 'statusName': 'In Progress'});
    expect(fx.lastBody['state_event'], 'reopen');
  });

  test('jira_move_to_status is label-only for other names', () {
    fx.tools.dispatch(
        'jira_move_to_status', {'key': 'gh-4', 'statusName': 'Blocked'});
    expect(fx.lastBody.containsKey('state_event'), isFalse);
  });
}

void _searchTests() {
  final fx = _Fixture();
  setUp(fx.start);
  tearDown(fx.stop);

  List<dynamic> search(String jql) =>
      jsonDecode(fx.tools.dispatch('jira_search_by_jql', {'jql': jql}))
          as List<dynamic>;

  test('key-scoped search fetches the issue and skips missing ones', () {
    final tickets = search('key in (gh-4, gh-99)');
    expect(tickets, hasLength(1));
    expect((tickets.first as Map)['key'], 'gh-4');
  });

  test('key AND labels filters client-side', () {
    expect(search("key = gh-4 AND labels = 'agent:dev'"), hasLength(1));
    expect(search("key = gh-4 AND labels = 'nope'"), isEmpty);
  });

  test('keyless search maps labels and status onto the list query', () {
    expect(search("labels = 'agent:dev' AND status = 'Open'"), hasLength(1));
    expect(fx.server.requests.last,
        'GET /api/v4/projects/o%2Fr/issues?labels=agent%3Adev&state=opened&per_page=100&page=1');
  });

  test('keyless multi-value labels are an honest unsupported error', () {
    final result = fx.tools
        .dispatch('jira_search_by_jql', {'jql': "labels in ('a', 'b')"});
    expect(_errOf(result), contains('unsupported JQL for GitLab'));
  });
}
