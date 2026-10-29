import 'dart:convert';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

import 'jira_test_support.dart';

/// Ticket-operation tests: getComments, assignTo, updateField,
/// createTicketBasic, getTransitions, deleteTicket, clearField
/// — plus executor dispatch.
void main() {
  tearDown(PropertyReader.clearOverrides);
  getCommentsTests();
  assignToTests();
  updateFieldTests();
  createTicketBasicTests();
  createTicketBasicLabelsTests();
  getTransitionsTests();
  deleteTicketTests();
  clearFieldTests();
  ticketOperationsExecutorReadDispatchTests();
  ticketOperationsExecutorWriteDispatchTests();
  ticketOperationsExecutorLabelsTests();
}

/// `jira_get_comments` — GET `/issue/{key}/comment`.
void getCommentsTests() {
  group('JiraClient.getComments', () {
    test('returns the comments array', () async {
      final f = mockJira(
          (o) => routeByPath({'/issue/PROJ-1/comment': _commentsBody}, o));
      final comments = await f.client.getComments('PROJ-1');
      expect(comments, hasLength(2));
      expect(comments[0]['body'], 'first');
      expect(comments[1]['body'], 'second');
      expect(f.adapter.calls.single.method, 'GET');
    });

    test('returns an empty list when comments is absent', () async {
      final f =
          mockJira((o) => routeByPath({'/issue/PROJ-1/comment': '{}'}, o));
      expect(await f.client.getComments('PROJ-1'), isEmpty);
    });

    test('returns an empty list when the body is not an object', () async {
      final f = mockJira((o) => '[]');
      expect(await f.client.getComments('PROJ-1'), isEmpty);
    });
  });
}

/// `jira_assign` — PUT `/issue/{key}/assignee`.
void assignToTests() {
  group('JiraClient.assignTo', () {
    test('PUTs the assignee body', () async {
      final f = mockJira((o) => '{}');
      await f.client.assignTo('PROJ-1', 'acct-42');
      final call = f.adapter.calls.single;
      expect(call.method, 'PUT');
      expect(call.path, endsWith('/issue/PROJ-1/assignee'));
      expect(jsonDecode(call.data as String), {'accountId': 'acct-42'});
    });
  });
}

/// `jira_update_field` — PUT `/issue/{key}` with `{fields:{field:value}}`.
void updateFieldTests() {
  group('JiraClient.updateField', () {
    test('PUTs a single-field update', () async {
      final f = mockJira((o) => '{}');
      await f.client.updateField('PROJ-1', 'priority', 'High');
      final call = f.adapter.calls.single;
      expect(call.method, 'PUT');
      expect(call.path, endsWith('/issue/PROJ-1'));
      expect(jsonDecode(call.data as String), {
        'fields': {'priority': 'High'},
      });
    });
  });
}

/// `jira_create_ticket` — POST `/issue`.
void createTicketBasicTests() {
  group('JiraClient.createTicketBasic', () {
    test('POSTs without description when omitted', () async {
      final f = mockJira((o) => routeByPath({'/issue': _createdBody}, o));
      final result = await f.client.createTicketBasic('PROJ', 'Task', 'Title');
      expect(result['key'], 'PROJ-2');
      final call = f.adapter.calls.single;
      expect(call.method, 'POST');
      expect(call.path, endsWith('/issue'));
      final decoded = jsonDecode(call.data as String) as Map<String, dynamic>;
      final fields = decoded['fields'] as Map<String, dynamic>;
      expect(fields['summary'], 'Title');
      expect(fields.containsKey('description'), isFalse);
    });

    test('includes description when provided', () async {
      final f = mockJira((o) => '{}');
      await f.client.createTicketBasic('PROJ', 'Bug', 'Title', 'Details here');
      final call = f.adapter.calls.single;
      final decoded = jsonDecode(call.data as String) as Map<String, dynamic>;
      final fields = decoded['fields'] as Map<String, dynamic>;
      expect(fields['description'], 'Details here');
      expect(fields['project'], {'key': 'PROJ'});
      expect(fields['issuetype'], {'name': 'Bug'});
    });

    test('returns an empty map when the body is not an object', () async {
      final f = mockJira((o) => '[]');
      expect(await f.client.createTicketBasic('PROJ', 'Task', 'T'), isEmpty);
    });
  });
}

/// gh-427 AC2/AC3/E1: `labels` mapping on [JiraClient.createTicketBasic].
void createTicketBasicLabelsTests() {
  group('JiraClient.createTicketBasic labels', () {
    test('maps labels into the create payload', () async {
      final f = mockJira((o) => _createdBody);
      await f.client.createTicketBasic(
        'PROJ',
        'Task',
        'Title',
        'Desc',
        ['development', 'ai_repo_task'],
      );
      final decoded = jsonDecode(f.adapter.calls.single.data as String) as Map;
      expect(decoded['fields']['labels'], ['development', 'ai_repo_task']);
    });

    test('omits the labels key when the list is empty', () async {
      // gh-427 E1: an empty list keeps the label-less wire shape.
      final f = mockJira((o) => _createdBody);
      await f.client.createTicketBasic('PROJ', 'Task', 'T', 'D', []);
      final fields =
          (jsonDecode(f.adapter.calls.single.data as String) as Map)['fields'];
      expect(fields.containsKey('labels'), isFalse);
    });

    test('absent labels keeps the payload byte-identical to the old shape',
        () async {
      // gh-427 AC3 golden: no labels arg ⇒ exactly the pre-change payload.
      final f = mockJira((o) => _createdBody);
      await f.client.createTicketBasic('PROJ', 'Task', 'Title');
      final body = jsonDecode(f.adapter.calls.single.data as String) as Map;
      expect(body, {
        'fields': {
          'project': {'key': 'PROJ'},
          'issuetype': {'name': 'Task'},
          'summary': 'Title',
        }
      });
    });
  });
}

/// `jira_get_transitions` — GET `/issue/{key}/transitions`.
void getTransitionsTests() {
  group('JiraClient.getTransitions', () {
    test('returns the transitions array', () async {
      final f = mockJira((o) =>
          routeByPath({'/issue/PROJ-1/transitions': _transitionsBody}, o));
      final transitions = await f.client.getTransitions('PROJ-1');
      expect(transitions, hasLength(2));
      expect(transitions[0]['name'], 'To Do');
      expect(transitions[1]['name'], 'Done');
      expect(f.adapter.calls.single.method, 'GET');
    });

    test('returns an empty list when transitions is absent', () async {
      final f = mockJira((o) => '{}');
      expect(await f.client.getTransitions('PROJ-1'), isEmpty);
    });
  });
}

/// `jira_delete_ticket` — DELETE `/issue/{key}`.
void deleteTicketTests() {
  group('JiraClient.deleteTicket', () {
    test('sends a DELETE for the key', () async {
      final f = mockJira((o) => '');
      await f.client.deleteTicket('PROJ-1');
      final call = f.adapter.calls.single;
      expect(call.method, 'DELETE');
      expect(call.path, endsWith('/issue/PROJ-1'));
    });
  });
}

/// `jira_clear_field` — PUT `/issue/{key}` with `{fields:{field:null}}`.
void clearFieldTests() {
  group('JiraClient.clearField', () {
    test('PUTs a null-field update', () async {
      final f = mockJira((o) => '{}');
      await f.client.clearField('PROJ-1', 'assignee');
      final call = f.adapter.calls.single;
      expect(call.method, 'PUT');
      expect(call.path, endsWith('/issue/PROJ-1'));
      expect(jsonDecode(call.data as String), {
        'fields': {'assignee': null},
      });
    });
  });
}

/// [JiraToolExecutor.execute] routes read ticket-operation tool names correctly.
void ticketOperationsExecutorReadDispatchTests() {
  group('JiraToolExecutor.execute (ticket operations, reads)', () {
    late _SpyJiraClient spy;
    late JiraToolExecutor executor;

    setUp(() {
      spy = _SpyJiraClient(mockHttp((o) => '{}').http);
      executor = JiraToolExecutor(spy);
    });

    test('routes jira_get_comments with key', () async {
      await executor.execute('jira_get_comments', {'key': 'PROJ-1'});
      expect(spy.calls, ['getComments:PROJ-1']);
    });

    test('routes jira_assign with key and accountId', () async {
      await executor.execute('jira_assign', {
        'key': 'PROJ-1',
        'accountId': 'acct-9',
      });
      expect(spy.calls, ['assignTo:PROJ-1:acct-9']);
    });

    test('routes jira_update_field with key, field, value', () async {
      await executor.execute('jira_update_field', {
        'key': 'PROJ-1',
        'field': 'priority',
        'value': 'High',
      });
      expect(spy.calls, ['updateField:PROJ-1:priority:High']);
    });

    test('routes jira_clear_field with key and field', () async {
      await executor.execute('jira_clear_field', {
        'key': 'PROJ-1',
        'field': 'assignee',
      });
      expect(spy.calls, ['clearField:PROJ-1:assignee']);
    });

    test('throws ArgumentError for an unknown tool', () {
      expect(() => executor.execute('jira_no_such', {}), throwsArgumentError);
    });
  });
}

/// [JiraToolExecutor.execute] routes write ticket-operation tool names correctly.
void ticketOperationsExecutorWriteDispatchTests() {
  group('JiraToolExecutor.execute (ticket operations, writes)', () {
    late _SpyJiraClient spy;
    late JiraToolExecutor executor;

    setUp(() {
      spy = _SpyJiraClient(mockHttp((o) => '{}').http);
      executor = JiraToolExecutor(spy);
    });

    test('routes jira_create_ticket with all fields', () async {
      await executor.execute('jira_create_ticket', {
        'project': 'PROJ',
        'issueType': 'Task',
        'summary': 'Title',
        'description': 'Desc',
      });
      expect(spy.calls, ['createTicketBasic:PROJ:Task:Title:Desc']);
    });

    test('routes jira_get_transitions with key', () async {
      await executor.execute('jira_get_transitions', {'key': 'PROJ-1'});
      expect(spy.calls, ['getTransitions:PROJ-1']);
    });

    test('routes jira_delete_ticket with key', () async {
      await executor.execute('jira_delete_ticket', {'key': 'PROJ-1'});
      expect(spy.calls, ['deleteTicket:PROJ-1']);
    });
  });
}

/// gh-427 AC5/E2/E5: loud labels validation at the executor boundary.
void ticketOperationsExecutorLabelsTests() {
  group('JiraToolExecutor.execute labels validation', () {
    late _SpyJiraClient spy;
    late JiraToolExecutor executor;

    setUp(() {
      spy = _SpyJiraClient(mockHttp((o) => '{}').http);
      executor = JiraToolExecutor(spy);
    });

    test('a non-string-list labels arg fails loudly with no HTTP', () async {
      // Wrong labels types never reach the wire (sync-throwing handlers).
      expect(
        () => executor.execute('jira_create_ticket', {
          'project': 'PROJ',
          'issueType': 'Task',
          'summary': 'T',
          'labels': 'development',
        }),
        throwsArgumentError,
      );
      expect(
        () => executor.execute('jira_create_ticket', {
          'project': 'PROJ',
          'issueType': 'Task',
          'summary': 'T',
          'labels': [1, 2],
        }),
        throwsArgumentError,
      );
      expect(spy.calls, isEmpty);
    });

    test('a top-level labels arg on with_json steers to fieldsJson', () async {
      // gh-427 E5: no third labels path — the error fires before the client
      // call, so no HTTP happens (the throw precedes createTicketWithJson).
      await expectLater(
        () => executor.execute('jira_create_ticket_with_json', {
          'project': 'PROJ',
          'fieldsJson': {'summary': 'S'},
          'labels': ['a'],
        }),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('fieldsJson'),
          ),
        ),
      );
    });
  });
}

/// Records every dispatched call then delegates to the real client logic.
class _SpyJiraClient extends JiraClient {
  _SpyJiraClient(super.http);

  final List<String> calls = [];

  @override
  Future<List<Map<String, dynamic>>> getComments(String key) {
    calls.add('getComments:$key');
    return super.getComments(key);
  }

  @override
  Future<void> assignTo(String key, String accountId) {
    calls.add('assignTo:$key:$accountId');
    return super.assignTo(key, accountId);
  }

  @override
  Future<void> updateField(String key, String field, Object value) {
    calls.add('updateField:$key:$field:$value');
    return super.updateField(key, field, value);
  }

  @override
  Future<void> clearField(String key, String field) {
    calls.add('clearField:$key:$field');
    return super.clearField(key, field);
  }

  @override
  Future<Map<String, dynamic>> createTicketBasic(
    String project,
    String issueType,
    String summary, [
    String? description,
    List<String>? labels,
  ]) {
    calls.add('createTicketBasic:$project:$issueType:$summary:$description');
    return super
        .createTicketBasic(project, issueType, summary, description, labels);
  }

  @override
  Future<List<Map<String, dynamic>>> getTransitions(String key) {
    calls.add('getTransitions:$key');
    return super.getTransitions(key);
  }

  @override
  Future<void> deleteTicket(String key) {
    calls.add('deleteTicket:$key');
    return super.deleteTicket(key);
  }
}

/// Canned `/issue/{key}/comment` response body.
const _commentsBody =
    '{"comments":[{"id":"1","body":"first"},{"id":"2","body":"second"}]}';

/// Canned `/issue` POST (create) response body.
const _createdBody = '{"key":"PROJ-2","id":"10042"}';

/// Canned `/issue/{key}/transitions` response body.
const _transitionsBody =
    '{"transitions":[{"id":"11","name":"To Do"},{"id":"31","name":"Done"}]}';
