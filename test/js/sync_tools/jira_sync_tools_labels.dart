// gh-427: create-tool `labels` support on the sync JS-bridge surface.
//
// Part of jira_sync_tools_test.dart — shares the fixture-server harness
// (`server` / `tools` / `errOf` / `_lastRequest`).
part of 'jira_sync_tools_test.dart';

/// Registers the sync create-labels groups.
void _testCreateLabels() {
  group('JiraSyncTools create labels', () {
    setUp(() async {
      server = JiraFixtureServer();
      await server.start();
      configureJira(server);
      tools = JiraSyncTools();
    });
    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });
    testcreatelabels_p1();
    testcreatelabels_p2();
  });
}

/// Base `jira_create_ticket_basic` args with an optional labels value.
Map<String, dynamic> _basicLabelsArgs({Object? labels}) => {
      'project': 'PROJ',
      'issueType': 'Task',
      'summary': 'Labeled',
      if (labels != null) 'labels': labels,
    };

/// Dispatches [tool] and returns the captured request's `fields` object.
dynamic _dispatchFields(String tool, Map<String, dynamic> args) => jsonDecode(
      jsonDecode(tools.dispatch(tool, args))['body'] as String,
    )['fields'];

/// Payload-mapping tests (AC1/AC2, E1, E3/E4).
void testcreatelabels_p1() {
  test('basic lands labels in the create fields (AC2)', () {
    expect(
      _dispatchFields('jira_create_ticket_basic',
          _basicLabelsArgs(labels: ['development', 'ai_repo_task'])),
      containsPair('labels', ['development', 'ai_repo_task']),
    );
  });

  test('with_parent lands labels next to the parent (AC1)', () {
    final fields = _dispatchFields('jira_create_ticket_with_parent', {
      ..._basicLabelsArgs(labels: ['development']),
      'issueType': 'Sub-task',
      'parentKey': 'EPIC-1',
    });
    expect(fields['labels'], ['development']);
    expect(fields['parent']['path'], contains('/issue/EPIC-1'));
  });

  test('an empty labels list omits the key (E1)', () {
    expect(
      _dispatchFields(
          'jira_create_ticket_basic', _basicLabelsArgs(labels: <String>[])),
      isNot(contains('labels')),
    );
  });

  test('labels pass through verbatim: duplicates and unicode (E3/E4)', () {
    expect(
      _dispatchFields('jira_create_ticket_basic',
          _basicLabelsArgs(labels: ['dev', 'dev', '测试', 'comma,label'])),
      containsPair('labels', ['dev', 'dev', '测试', 'comma,label']),
    );
  });
}

/// Validation and escape-hatch tests (AC5/E2, E5, REG-2).
void testcreatelabels_p2() {
  test('a non-list labels value errors with zero HTTP (AC5/E2)', () {
    final error = errOf(tools.dispatch(
        'jira_create_ticket_basic', _basicLabelsArgs(labels: 'development')));
    expect(error['error'], contains('must be a list of strings'));
    expect(_lastRequest(server)['line'], isNot(startsWith('POST')));
  });

  test('non-string labels entries error with zero HTTP (AC5/E2)', () {
    final error = errOf(tools.dispatch(
        'jira_create_ticket_basic', _basicLabelsArgs(labels: [1, 2])));
    expect(error['error'], contains('must be a list of strings'));
    expect(_lastRequest(server)['line'], isNot(startsWith('POST')));
  });

  test('with_parent validates labels before the parent fetch (AC5)', () {
    final error = errOf(tools.dispatch('jira_create_ticket_with_parent', {
      ..._basicLabelsArgs(labels: 'development'),
      'issueType': 'Sub-task',
      'parentKey': 'EPIC-1',
    }));
    expect(error['error'], contains('must be a list of strings'));
    // No request at all — not even the parent GET — reached the server.
    expect(_lastRequest(server)['line'], isEmpty);
  });

  test('top-level labels on with_json steers to fieldsJson (E5)', () {
    final error = errOf(tools.dispatch('jira_create_ticket_with_json', {
      'project': 'PROJ',
      'fieldsJson': {'summary': 'From JSON'},
      'labels': ['a'],
    }));
    expect(error['error'], contains('fieldsJson'));
    expect(_lastRequest(server)['line'], isNot(startsWith('POST')));
  });

  test('labels inside fieldsJson still flow through with_json (REG-2)', () {
    final fields = _dispatchFields('jira_create_ticket_with_json', {
      'project': 'PROJ',
      'fieldsJson': {
        'summary': 'From JSON',
        'labels': ['via-json']
      },
    });
    expect(fields['labels'], ['via-json']);
  });
}
