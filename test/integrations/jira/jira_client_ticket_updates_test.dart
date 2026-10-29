import 'dart:convert';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

import 'jira_test_support.dart';

/// Ticket-update tests: setFixVersion, setPriority, getSubtasks,
/// updateDescription, createTicketWithParent, updateTicketParent — plus
/// executor dispatch.
void main() {
  tearDown(PropertyReader.clearOverrides);
  setFixVersionTests();
  setPriorityTests();
  getSubtasksTests();
  updateDescriptionTests();
  createTicketWithParentTests();
  createTicketWithParentLabelsTests();
  updateTicketParentTests();
  ticketUpdatesExecutorDispatchTests();
  ticketUpdatesExecutorLabelsTests();
}

/// `jira_set_fix_version` — PUT `issue/{key}` with fixVersions field.
void setFixVersionTests() {
  group('JiraClient.setFixVersion', () {
    test('PUTs the fixVersions field', () async {
      final f = mockJira((o) => '{}');
      await f.client.setFixVersion('PROJ-1', '1.0');
      final call = f.adapter.calls.single;
      expect(call.method, 'PUT');
      expect(call.path, endsWith('/issue/PROJ-1'));
      expect(jsonDecode(call.data as String), {
        'fields': {
          'fixVersions': [
            {'name': '1.0'}
          ],
        },
      });
    });
  });
}

/// `jira_set_priority` — PUT `issue/{key}` with priority field.
void setPriorityTests() {
  group('JiraClient.setPriority', () {
    test('PUTs the priority field', () async {
      final f = mockJira((o) => '{}');
      await f.client.setPriority('PROJ-1', 'High');
      final call = f.adapter.calls.single;
      expect(call.method, 'PUT');
      expect(call.path, endsWith('/issue/PROJ-1'));
      expect(jsonDecode(call.data as String), {
        'fields': {
          'priority': {'name': 'High'},
        },
      });
    });
  });
}

/// `jira_get_subtasks` — parses `fields.subtasks` from the ticket.
void getSubtasksTests() {
  group('JiraClient.getSubtasks', () {
    test('returns the fields.subtasks array', () async {
      final f =
          mockJira((o) => routeByPath({'/issue/PROJ-1': _subtasksBody}, o));
      final result = await f.client.getSubtasks('PROJ-1');
      expect(result, hasLength(2));
      expect(result[0]['key'], 'PROJ-2');
      expect(result[1]['key'], 'PROJ-3');
    });

    test('returns an empty list when subtasks is absent', () async {
      final f = mockJira((o) => routeByPath(
          {'/issue/PROJ-1': _noSubtasksBody}, o,
          fallback: _noSubtasksBody));
      expect(await f.client.getSubtasks('PROJ-1'), isEmpty);
    });
  });
}

/// `jira_update_description` — PUT `issue/{key}` with description field.
void updateDescriptionTests() {
  group('JiraClient.updateDescription', () {
    test('PUTs the description field', () async {
      final f = mockJira((o) => '{}');
      await f.client.updateDescription('PROJ-1', 'New desc');
      final call = f.adapter.calls.single;
      expect(call.method, 'PUT');
      expect(call.path, endsWith('/issue/PROJ-1'));
      expect(jsonDecode(call.data as String), {
        'fields': {'description': 'New desc'},
      });
    });
  });
}

/// `jira_create_ticket_with_parent` — POST `issue` with parent link.
void createTicketWithParentTests() {
  group('JiraClient.createTicketWithParent', () {
    test('POSTs with the parent link', () async {
      final f = mockJira((o) => routeByPath({'/issue': _createdBody}, o));
      final result = await f.client.createTicketWithParent(
        'PROJ',
        'Sub-task',
        'Title',
        'PROJ-1',
      );
      expect(result['key'], 'PROJ-2');
      final call = f.adapter.calls.single;
      expect(call.method, 'POST');
      expect(call.path, endsWith('/issue'));
      final decoded = jsonDecode(call.data as String) as Map<String, dynamic>;
      final fields = decoded['fields'] as Map<String, dynamic>;
      expect(fields['summary'], 'Title');
      expect(fields['parent'], {'key': 'PROJ-1'});
      expect(fields['project'], {'key': 'PROJ'});
      expect(fields['issuetype'], {'name': 'Sub-task'});
    });

    test('includes the description when provided', () async {
      final f = mockJira((o) => routeByPath({'/issue': _createdBody}, o));
      await f.client
          .createTicketWithParent('PROJ', 'Sub-task', 'Title', 'PROJ-1', 'D');
      final decoded = jsonDecode(f.adapter.calls.single.data as String);
      expect(decoded['fields']['description'], 'D');
    });

    test('returns an empty map when the body is not an object', () async {
      final f = mockJira((o) => '[]');
      expect(
        await f.client.createTicketWithParent('PROJ', 'Task', 'T', 'PROJ-1'),
        isEmpty,
      );
    });
  });
}

/// gh-427 AC1/E1: `labels` mapping on [JiraClient.createTicketWithParent].
void createTicketWithParentLabelsTests() {
  group('JiraClient.createTicketWithParent labels', () {
    test('maps labels into the create payload', () async {
      final f = mockJira((o) => routeByPath({'/issue': _createdBody}, o));
      await f.client.createTicketWithParent(
        'PROJ',
        'Sub-task',
        'Title',
        'PROJ-1',
        'Desc',
        ['development', 'ai_repo_task'],
      );
      final decoded = jsonDecode(f.adapter.calls.single.data as String) as Map;
      expect(decoded['fields']['labels'], ['development', 'ai_repo_task']);
    });

    test('omits the labels key when the list is empty', () async {
      // gh-427 E1: an empty list keeps the label-less wire shape.
      final f = mockJira((o) => routeByPath({'/issue': _createdBody}, o));
      await f.client.createTicketWithParent(
        'PROJ',
        'Sub-task',
        'Title',
        'PROJ-1',
        null,
        [],
      );
      final fields =
          (jsonDecode(f.adapter.calls.single.data as String) as Map)['fields'];
      expect(fields.containsKey('labels'), isFalse);
    });
  });
}

/// `jira_update_ticket_parent` — PUT `issue/{key}` with the parent field.
void updateTicketParentTests() {
  group('JiraClient.updateTicketParent', () {
    test('PUTs the parent field', () async {
      final f = mockJira((o) => '{}');
      await f.client.updateTicketParent('PROJ-2', 'PROJ-1');
      final call = f.adapter.calls.single;
      expect(call.method, 'PUT');
      expect(call.path, endsWith('/issue/PROJ-2'));
      final decoded = jsonDecode(call.data as String) as Map<String, dynamic>;
      final fields = decoded['fields'] as Map<String, dynamic>;
      expect(fields['parent'], {'key': 'PROJ-1'});
      expect(fields.keys, ['parent']);
    });
  });
}

/// [JiraToolExecutor.execute] routes ticket-update tool names correctly.
void ticketUpdatesExecutorDispatchTests() {
  group('JiraToolExecutor.execute (ticket updates)', () {
    late _SpyJiraClient spy;
    late JiraToolExecutor executor;

    setUp(() {
      spy = _SpyJiraClient(mockHttp((o) => '{}').http);
      executor = JiraToolExecutor(spy);
    });

    test('routes jira_set_fix_version with key and fixVersion', () async {
      await executor.execute('jira_set_fix_version', {
        'key': 'PROJ-1',
        'fixVersion': '1.0',
      });
      expect(spy.calls, ['setFixVersion:PROJ-1:1.0']);
    });

    test('routes jira_set_priority with key and priority', () async {
      await executor.execute('jira_set_priority', {
        'key': 'PROJ-1',
        'priority': 'High',
      });
      expect(spy.calls, ['setPriority:PROJ-1:High']);
    });

    test('routes jira_update_description with key and description', () async {
      await executor.execute('jira_update_description', {
        'key': 'PROJ-1',
        'description': 'desc',
      });
      expect(spy.calls, ['updateDescription:PROJ-1:desc']);
    });

    test('routes jira_create_ticket_with_parent', () async {
      await executor.execute('jira_create_ticket_with_parent', {
        'project': 'PROJ',
        'issueType': 'Task',
        'summary': 'Title',
        'parentKey': 'PROJ-1',
      });
      expect(spy.calls, ['createTicketWithParent:PROJ:Task:Title:PROJ-1']);
    });

    test('routes jira_update_ticket_parent with key and parentKey', () async {
      await executor.execute('jira_update_ticket_parent', {
        'key': 'PROJ-2',
        'parentKey': 'PROJ-1',
      });
      expect(spy.calls, ['updateTicketParent:PROJ-2:PROJ-1']);
    });

    test('routes jira_get_subtasks with key', () async {
      await executor.execute('jira_get_subtasks', {'key': 'PROJ-1'});
      expect(spy.calls, ['getSubtasks:PROJ-1']);
    });
  });
}

/// gh-427 AC5: with_parent labels validation precedes the parent fetch.
void ticketUpdatesExecutorLabelsTests() {
  group('JiraToolExecutor.execute with_parent labels validation', () {
    late _SpyJiraClient spy;
    late JiraToolExecutor executor;

    setUp(() {
      spy = _SpyJiraClient(mockHttp((o) => '{}').http);
      executor = JiraToolExecutor(spy);
    });

    test('rejects a malformed labels arg with no HTTP', () async {
      await expectLater(
        () => executor.execute('jira_create_ticket_with_parent', {
          'project': 'PROJ',
          'issueType': 'Task',
          'summary': 'Title',
          'parentKey': 'PROJ-1',
          'labels': [42],
        }),
        throwsArgumentError,
      );
      expect(spy.calls, isEmpty);
    });
  });
}

/// Records every dispatched call then delegates to the real client logic.
class _SpyJiraClient extends JiraClient {
  _SpyJiraClient(super.http);

  final List<String> calls = [];

  @override
  Future<void> setFixVersion(String key, String versionName) {
    calls.add('setFixVersion:$key:$versionName');
    return super.setFixVersion(key, versionName);
  }

  @override
  Future<void> setPriority(String key, String priorityName) {
    calls.add('setPriority:$key:$priorityName');
    return super.setPriority(key, priorityName);
  }

  @override
  Future<List<Map<String, dynamic>>> getSubtasks(String key) {
    calls.add('getSubtasks:$key');
    return super.getSubtasks(key);
  }

  @override
  Future<void> updateDescription(String key, String description) {
    calls.add('updateDescription:$key:$description');
    return super.updateDescription(key, description);
  }

  @override
  Future<void> updateTicketParent(String key, String parentKey) {
    calls.add('updateTicketParent:$key:$parentKey');
    return super.updateTicketParent(key, parentKey);
  }

  @override
  Future<Map<String, dynamic>> createTicketWithParent(
    String project,
    String issueType,
    String summary,
    String parentKey, [
    String? description,
    List<String>? labels,
  ]) {
    calls.add('createTicketWithParent:$project:$issueType:$summary:$parentKey');
    return super.createTicketWithParent(
      project,
      issueType,
      summary,
      parentKey,
      description,
      labels,
    );
  }
}

/// Canned `issue/{key}` body containing subtasks.
const _subtasksBody =
    '{"key":"PROJ-1","fields":{"subtasks":[{"key":"PROJ-2"},{"key":"PROJ-3"}]}}';

/// Canned `issue/{key}` body without subtasks.
const _noSubtasksBody = '{"key":"PROJ-1","fields":{}}';

/// Canned `/issue` POST (create) response body.
const _createdBody = '{"key":"PROJ-2","id":"10042"}';
