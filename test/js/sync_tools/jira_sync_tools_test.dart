import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/sync_http_client.dart';
import 'package:dmtools/src/js/sync_tools/jira_sync_tools.dart';
import 'package:test/test.dart';

part 'jira_sync_tools_labels.dart';

/// Shared fixtures for the fixture-server groups (each group's setUp
/// rebinds the server and tools).
late JiraFixtureServer server;
late JiraSyncTools tools;
late Directory tmp;

/// Tests for [JiraSyncTools] — the public sync executors for `jira_*` tools.
///
/// Server-dependent tests run a Python fixture server subprocess (same
/// constraint as test/js/sync_tool_dispatch_test.dart: the Dart event loop
/// is frozen during `Process.runSync('curl', …)`).
void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });
  _testHandlerCatalog();
  _testDispatchErrors();
  if (hasPython3()) {
    _testNewWriteTools();
    _testCreateLabels();
    _testLinkIssues();
    _testAttachFile();
    _testFieldCustomCode();
    _testUpdateFieldEngine();
  }
}

/// Manages the Python fixture-server subprocess lifecycle.
class JiraFixtureServer {
  Process? _process;

  /// The bound port (valid after [start]).
  int port = 0;

  /// Starts the fixture server on an ephemeral port.
  Future<void> start() async {
    final script = '${Directory.current.path}'
        '/test/js/sync_tools/jira_fixture_server.py';
    _process = await Process.start('python3', [script, '0']);
    final firstLine = await _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    port = int.parse(firstLine.trim());
  }

  /// Kills the server process.
  void stop() => _process?.kill();
}

/// Whether `python3` is available on this system.
bool hasPython3() {
  try {
    return Process.runSync('which', ['python3']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// The `{"error": …}` payload decoded from a [JiraSyncTools] result.
Map<String, dynamic> errOf(String result) =>
    jsonDecode(result) as Map<String, dynamic>;

/// Starts [server] and points the Jira config at it.
void configureJira(JiraFixtureServer server, {String token = 'tok'}) {
  PropertyReader.setOverrides({
    'JIRA_BASE_PATH': 'http://127.0.0.1:${server.port}',
    'JIRA_LOGIN_PASS_TOKEN': token,
    'JIRA_AUTH_TYPE': 'Basic',
    'JIRA_RETRY_ENABLED': 'false',
  });
}

void _testHandlerCatalog() {
  group('JiraSyncTools handler catalog', () {
    test('exposes the canonical and alias jira tool names', () {
      final names = const JiraSyncTools().handlers.keys.toSet();
      expect(
          names,
          containsAll([
            'jira_get_ticket',
            'jira_post_comment',
            'jira_search_by_jql',
            'jira_add_label',
            'jira_remove_label',
            'jira_move_to_status',
            'jira_get_comments',
            'jira_update_field',
            'jira_update_description',
            'jira_get_transitions',
            'jira_get_my_profile',
            'jira_delete_ticket',
            'jira_create_ticket_basic',
            'jira_create_ticket',
            'jira_assign_ticket_to',
            'jira_assign_to',
            'jira_assign',
            'tracker_assign_ticket',
            'jira_set_priority',
            'jira_create_ticket_with_parent',
            'jira_create_ticket_with_json',
            'jira_link_issues',
            'tracker_link_tickets',
            'jira_get_field_custom_code',
            'jira_attach_file_to_ticket',
          ]));
    });
  });
}

void _testDispatchErrors() {
  group('JiraSyncTools dispatch errors', () {
    tearDown(PropertyReader.clearOverrides);

    test('unknown tool name yields the unsupported-tool error', () {
      expect(
        errOf(const JiraSyncTools().dispatch('jira_mystery', {})),
        {'error': 'Unsupported Jira tool: jira_mystery'},
      );
    });

    test('blank config yields the not-configured error', () {
      PropertyReader.setOverrides({
        'JIRA_BASE_PATH': '',
        'JIRA_LOGIN_PASS_TOKEN': '',
      });
      expect(
        errOf(const JiraSyncTools().dispatch('jira_set_priority', {})),
        {'error': 'Jira not configured'},
      );
    });
  });
}

void _testNewWriteTools() {
  group('JiraSyncTools new write tools', () {
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

    testnewwritetools_p1();
    testCreateTicketWithParent();
    testnewwritetools_p2();
    testPostCommentConversion();
  });
}

/// gh-191 / P6-JSY-09: `jira_post_comment` must convert Markdown bodies to
/// Jira wiki markup before POSTing (Java `JiraClient.postComment` with
/// `TextType.MARKDOWN`).
void testPostCommentConversion() {
  test('jira_post_comment converts markdown to Jira markup', () {
    final body = jsonDecode(tools.dispatch('jira_post_comment', {
      'key': 'P-1',
      'comment': '## Done\n\n- **fixed** the bug\n\n```dart\nx();\n```',
    }));
    expect(body['method'], 'POST');
    expect(body['path'], '/rest/api/latest/issue/P-1/comment');
    final posted = jsonDecode(body['body'] as String)['body'] as String;
    expect(
      posted,
      'h2. Done\n\n- *fixed* the bug\n\n{code:dart}x();{code}',
    );
  });

  test('jira_post_comment keeps plain comments byte-for-byte', () {
    final body = jsonDecode(tools.dispatch('jira_post_comment', {
      'key': 'P-1',
      'comment': 'plain text, no markup',
    }));
    final posted = jsonDecode(body['body'] as String)['body'] as String;
    expect(posted, 'plain text, no markup');
  });
}

void testnewwritetools_p1() {
  test('jira_set_priority PUTs the priority name', () {
    final body = jsonDecode(
      tools.dispatch('jira_set_priority', {'key': 'P-1', 'priority': 'High'}),
    );
    expect(body['method'], 'PUT');
    expect(body['path'], '/rest/api/latest/issue/P-1');
    final fields = jsonDecode(body['body'] as String)['fields'];
    expect(fields['priority'], {'name': 'High'});
  });

  test('jira_assign_ticket_to PUTs accountId to the assignee endpoint', () {
    final body = jsonDecode(tools.dispatch('jira_assign_ticket_to', {
      'key': 'P-1',
      'accountId': 'acc-7',
    }));
    expect(body['method'], 'PUT');
    expect(body['path'], '/rest/api/latest/issue/P-1/assignee');
    expect(jsonDecode(body['body'] as String)['accountId'], 'acc-7');
  });

  test('tracker_assign_ticket alias routes to the assign executor', () {
    final body = jsonDecode(tools.dispatch('tracker_assign_ticket', {
      'key': 'P-1',
      'accountId': 'acc-7',
    }));
    expect(body['path'], '/rest/api/latest/issue/P-1/assignee');
  });
}

void testCreateTicketWithParent() {
  test('jira_create_ticket_with_parent embeds the fetched parent object', () {
    final body = jsonDecode(tools.dispatch('jira_create_ticket_with_parent', {
      'project': 'PROJ',
      'issueType': 'Sub-task',
      'summary': 'Do the thing',
      'description': 'Details here',
      'parentKey': 'EPIC-1',
    }));
    expect(body['method'], 'POST');
    expect(body['path'], '/rest/api/latest/issue');
    final fields = jsonDecode(body['body'] as String)['fields'];
    // Java `createTicketInProjectWithParent`: the parent ticket is fetched
    // first and embedded as the full JSON object, not a key reference.
    expect(fields['parent']['method'], 'GET');
    expect(fields['parent']['path'], contains('/issue/EPIC-1'));
    expect(fields['description'], 'Details here');
  });

  test('jira_create_ticket_with_parent fails upfront on a missing parent', () {
    final result = tools.dispatch('jira_create_ticket_with_parent', {
      'project': 'PROJ',
      'issueType': 'Sub-task',
      'summary': 'Do the thing',
      'description': 'Details here',
      'parentKey': 'NOPE-1',
    });
    final body = jsonDecode(result) as Map<String, dynamic>;
    expect(body['error'], isNotNull);
    // No create request may reach the wire after the parent fetch fails.
    expect(_lastRequest(server)['line'], contains('GET'));
  });
}

void testnewwritetools_p2() {
  test('jira_create_ticket_with_json merges fieldsJson over project', () {
    final body = jsonDecode(tools.dispatch('jira_create_ticket_with_json', {
      'project': 'PROJ',
      'fieldsJson': {
        'summary': 'From JSON',
        'issuetype': {'name': 'Bug'},
      },
    }));
    expect(body['method'], 'POST');
    final fields = jsonDecode(body['body'] as String)['fields'];
    expect(fields['project'], {'key': 'PROJ'});
    expect(fields['summary'], 'From JSON');
    expect(fields['issuetype'], {'name': 'Bug'});
  });

  test('jira_create_ticket_with_json accepts a JSON-string fieldsJson', () {
    final body = jsonDecode(tools.dispatch('jira_create_ticket_with_json', {
      'project': 'PROJ',
      'fieldsJson': '{"summary": "FromString"}',
    }));
    final fields = jsonDecode(body['body'] as String)['fields'];
    expect(fields['summary'], 'FromString');
  });

  test('jira_create_ticket_with_json surfaces the full Jira error body', () {
    // gh-403: a Jira 400 (missing required Epic Name) used to reach agent
    // logs as `{}` — the error envelope must carry the status and the
    // complete errors map, not a 120-char snippet.
    final result = tools.dispatch('jira_create_ticket_with_json', {
      'project': 'FAILCREATE',
      'fieldsJson': {
        'summary': 'Epic without Epic Name',
        'issuetype': {'name': 'Epic'},
      },
    });
    final error = errOf(result)['error'] as String;
    expect(error, startsWith('HTTP 400:'));
    expect(error, contains('Epic Name is required'));
    expect(error, contains('split the content across multiple lines'));
    expect(error.length, greaterThan(120));
  });

  test('jira_create_ticket alias routes to the create executor', () {
    final body = jsonDecode(tools.dispatch('jira_create_ticket', {
      'project': 'PROJ',
      'issueType': 'Task',
      'summary': 'S',
    }));
    expect(body['method'], 'POST');
    expect(body['path'], '/rest/api/latest/issue');
  });
}

void _testLinkIssues() {
  group('JiraSyncTools jira_link_issues', () {
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

    testlinkissues_p1();
  });
}

void testlinkissues_p1() {
  test('relationship matched by type name maps source to outward', () {
    final body = jsonDecode(tools.dispatch('jira_link_issues', {
      'sourceKey': 'EPIC-1',
      'anotherKey': 'STORY-1',
      'relationship': 'Blocks',
    }));
    expect(body['method'], 'POST');
    expect(body['path'], '/rest/api/latest/issueLink');
    expect(jsonDecode(body['body'] as String), {
      'type': {'name': 'Blocks'},
      'outwardIssue': {'key': 'EPIC-1'},
      'inwardIssue': {'key': 'STORY-1'},
    });
  });

  test('relationship matched by inward description maps the same way', () {
    final body = jsonDecode(tools.dispatch('jira_link_issues', {
      'sourceKey': 'A-1',
      'anotherKey': 'B-1',
      'relationship': 'blocks',
    }));
    final sent = jsonDecode(body['body'] as String);
    expect(sent['outwardIssue'], {'key': 'A-1'});
    expect(sent['inwardIssue'], {'key': 'B-1'});
  });

  test('relationship matched by outward description swaps the sides', () {
    final body = jsonDecode(tools.dispatch('jira_link_issues', {
      'sourceKey': 'A-1',
      'anotherKey': 'B-1',
      'relationship': 'is blocked by',
    }));
    final sent = jsonDecode(body['body'] as String);
    expect(sent['inwardIssue'], {'key': 'A-1'});
    expect(sent['outwardIssue'], {'key': 'B-1'});
  });

  test('unknown relationship yields an error', () {
    expect(
      errOf(tools.dispatch('jira_link_issues', {
        'sourceKey': 'A-1',
        'anotherKey': 'B-1',
        'relationship': 'Nonsense',
      })),
      {'error': 'Unknown relationship type: Nonsense'},
    );
  });
}

void _testAttachFile() {
  group('JiraSyncTools jira_attach_file_to_ticket', () {
    setUp(() async {
      server = JiraFixtureServer();
      await server.start();
      configureJira(server);
      tools = JiraSyncTools();
      tmp = await Directory.systemTemp.createTemp('dmtools_jira_attach_');
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
      tmp.deleteSync(recursive: true);
    });

    testattachfile_p1();
    testattachfile_p2();
  });
}

void testattachfile_p1() {
  test('uploads via multipart POST and reports success', () {
    final file = File('${tmp.path}/doc.md')..writeAsStringSync('# report body');
    final result = tools.dispatch('jira_attach_file_to_ticket', {
      'ticketKey': 'P-1',
      'name': 'doc.md',
      'contentType': 'text/markdown',
      'filePath': file.path,
    });
    expect(jsonDecode(result), {
      'status': 'success',
      'message': "File 'doc.md' attached to ticket P-1",
      'ticket': 'P-1',
      'fileName': 'doc.md',
    });
    final last = _lastRequest(server);
    expect(last['line'], 'POST /rest/api/latest/issue/P-1/attachments');
    expect(last['body'] as String, contains('name="doc.md"'));
    expect(last['body'] as String, contains('text/markdown'));
  });

  test('defaults the content type to image/*', () {
    final file = File('${tmp.path}/pic.png')..writeAsBytesSync([1, 2, 3]);
    tools.dispatch('jira_attach_file_to_ticket', {
      'ticketKey': 'P-1',
      'name': 'pic.png',
      'filePath': file.path,
    });
    final last = _lastRequest(server);
    expect(last['body'] as String, contains('image/*'));
  });

  test('skips the upload when an attachment with the name exists', () {
    final file = File('${tmp.path}/doc.md')..writeAsStringSync('x');
    final result = tools.dispatch('jira_attach_file_to_ticket', {
      'ticketKey': '__attached',
      'name': 'doc.md',
      'contentType': 'text/markdown',
      'filePath': file.path,
    });
    expect(jsonDecode(result)['status'], 'success');
    // The last request is the attachment-listing GET — no POST happened.
    expect(
      _lastRequest(server)['line'],
      'GET /rest/api/latest/issue/__attached?fields=attachment,summary',
    );
  });
}

void testattachfile_p2() {
  test('missing local file yields an error', () {
    expect(
      errOf(tools.dispatch('jira_attach_file_to_ticket', {
        'ticketKey': 'P-1',
        'name': 'nope.md',
        'filePath': '${tmp.path}/nope.md',
      })),
      {'error': 'File does not exist: ${tmp.path}/nope.md'},
    );
  });
}

/// Fetches the fixture server's record of the last served request.
Map<String, dynamic> _lastRequest(JiraFixtureServer server) {
  final resp = SyncHttpClient.get('http://127.0.0.1:${server.port}/__last');
  return jsonDecode(resp.body) as Map<String, dynamic>;
}

void _testFieldCustomCode() {
  group('JiraSyncTools jira_get_field_custom_code', () {
    setUp(() async {
      server = JiraFixtureServer();
      await server.start();
      tools = JiraSyncTools();
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    test('returns the best matching custom field id as a JSON string', () {
      configureJira(server);
      final result = tools.dispatch('jira_get_field_custom_code', {
        'project': 'PROJ',
        'fieldName': 'Story Points',
      });
      // JSON string: the C bridge unmarshals it to the JS string value.
      expect(result, '"customfield_10002"');
    });

    test('no matching field yields JSON null (Java returns null)', () {
      configureJira(server);
      final result = tools.dispatch('jira_get_field_custom_code', {
        'project': 'PROJ',
        'fieldName': 'Nope Field',
      });
      expect(result, 'null');
    });

    test('falls back to createmeta when the field listing fails', () {
      // The fixture server 503s /field when the token contains 'fieldfail';
      // the createmeta fallback body is an object, which — as in Java —
      // yields no array parse and therefore no field id.
      configureJira(server, token: 'fieldfail');
      final result = tools.dispatch('jira_get_field_custom_code', {
        'project': 'PROJ',
        'fieldName': 'Story Points',
      });
      expect(result, 'null');
    });
  });
}

void _testUpdateFieldEngine() {
  group('JiraSyncTools jira_update_field engine', () {
    setUp(() async {
      server = JiraFixtureServer();
      await server.start();
      tools = JiraSyncTools();
      configureJira(server);
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    testupdatefield_p1();
    testupdatefield_p2();
    testupdatefield_p3();
    testupdatefield_p4();
    testupdatefield_p5();
  });
}

void testupdatefield_p1() {
  test('system field PUTs the update-verb payload without resolution', () {
    final result = tools.dispatch('jira_update_field', {
      'key': 'PROJ-1',
      'field': 'labels',
      'value': 'x',
    });
    final last = _lastRequest(server);
    expect(last['line'], 'PUT /rest/api/latest/issue/PROJ-1');
    expect(
      jsonDecode(last['body'] as String),
      {
        'update': {
          'labels': [
            {'set': 'x'},
          ],
        },
      },
    );
    // `labels` is absent from the field listing — a name-resolution
    // path would have answered "No fields found" instead.
    expect(
      jsonDecode(result),
      "Field 'labels' updated successfully on ticket PROJ-1",
    );
  });

  test('customfield id skips name resolution', () {
    final result = tools.dispatch('jira_update_field', {
      'key': 'PROJ-1',
      'field': 'customfield_10091',
      'value': 'v',
    });
    final last = _lastRequest(server);
    expect(last['line'], 'PUT /rest/api/latest/issue/PROJ-1');
    expect(
      jsonDecode(result),
      "Field 'customfield_10091' updated successfully on ticket PROJ-1",
    );
  });
}

void testupdatefield_p2() {
  test('empty value clears the field with a fields-null payload', () {
    final result = tools.dispatch('jira_update_field', {
      'key': 'PROJ-1',
      'field': 'customfield_10091',
      'value': '',
    });
    final last = _lastRequest(server);
    expect(last['line'], 'PUT /rest/api/latest/issue/PROJ-1');
    expect(
      jsonDecode(last['body'] as String),
      {
        'fields': {'customfield_10091': null},
      },
    );
    // Java clearField returns the raw PUT response.
    final echo = jsonDecode(result) as Map<String, dynamic>;
    expect(echo['method'], 'PUT');
  });

  test('string values are coerced to bool/int/double/JSON', () {
    final cases = <String, dynamic>{
      '8': 8,
      'true': true,
      '8.5': 8.5,
      '{"a":1}': {
        'a': 1,
      },
      '[1,2]': [1, 2],
    };
    cases.forEach((raw, expected) {
      tools.dispatch('jira_update_field', {
        'key': 'PROJ-1',
        'field': 'customfield_10091',
        'value': raw,
      });
      final body = jsonDecode(_lastRequest(server)['body'] as String)
          as Map<String, dynamic>;
      final update = (body['update'] as Map)['customfield_10091'] as List;
      expect((update.single as Map)['set'], expected, reason: "value '$raw'");
    });
    // Non-JSON text stays a string.
    tools.dispatch('jira_update_field', {
      'key': 'PROJ-1',
      'field': 'customfield_10091',
      'value': '{code:mermaid}\ngraph TD\n{code}',
    });
    final body = jsonDecode(_lastRequest(server)['body'] as String) as Map;
    final set =
        ((body['update'] as Map)['customfield_10091'] as List).single as Map;
    expect(set['set'], '{code:mermaid}\ngraph TD\n{code}');
  });
}

void testupdatefield_p3() {
  test('field name resolves to ALL active customfields and summarizes', () {
    final result = tools.dispatch('jira_update_field', {
      'key': 'PROJ-1',
      'field': 'Story Points',
      'value': '8',
    });
    expect(
      jsonDecode(result),
      '✅ Updated customfield_10001\n'
      '✅ Updated customfield_10002\n'
      '\n'
      "Updated 2 of 2 fields with name 'Story Points' for ticket PROJ-1",
    );
    final last = _lastRequest(server);
    expect(last['line'], 'PUT /rest/api/latest/issue/PROJ-1');
    // The coerced number — not the raw string — reaches the wire.
    final set = ((jsonDecode(last['body'] as String) as Map)['update']
        as Map)['customfield_10002'] as List;
    expect((set.single as Map)['set'], 8);
  });

  test('single-match field name skips the ✅ lines', () {
    final result = tools.dispatch('jira_update_field', {
      'key': 'PROJ-1',
      'field': 'Dependencies',
      'value': 'A > B',
    });
    expect(
      jsonDecode(result),
      "Field 'Dependencies' updated successfully on ticket PROJ-1",
    );
  });
}

void testupdatefield_p4() {
  test('unknown field name returns a no-fields error envelope', () {
    final result = tools.dispatch('jira_update_field', {
      'key': 'PROJ-1',
      'field': 'Nope Field',
      'value': 'v',
    });
    expect(
      errOf(result),
      {'error': "No fields found with name 'Nope Field'"},
    );
  });

  test('per-field failures produce ❌ lines and a failed summary', () {
    final result = tools.dispatch('jira_update_field', {
      'key': 'PROJ-FAIL',
      'field': 'Story Points',
      'value': '8',
    });
    final decoded = jsonDecode(result) as String;
    expect(decoded, contains('❌ Failed customfield_10001'));
    expect(decoded, contains('❌ Failed customfield_10002'));
    expect(
      decoded,
      contains(
        "Updated 0 of 2 fields with name 'Story Points' for ticket "
        'PROJ-FAIL (2 failed)',
      ),
    );
  });
}

/// gh-403: name-path failures must surface as `{"error": …}` envelopes
/// carrying the HTTP status and the full Jira error body.
void testupdatefield_p5() {
  test('single-field failure through a name carries status and body', () {
    // gh-403: the failure was collapsed to a plain sentence — the HTTP
    // status and the Jira error body vanished, so agent logs showed
    // nothing diagnosable.
    final result = tools.dispatch('jira_update_field', {
      'key': 'PROJ-FAIL',
      'field': 'Dependencies',
      'value': 'v',
    });
    final error = errOf(result)['error'] as String;
    expect(
      error,
      startsWith(
        "Failed to update field 'Dependencies' on ticket PROJ-FAIL:",
      ),
    );
    expect(error, contains('HTTP 400'));
    expect(error, contains('Boom'));
    expect(error, contains('nope'));
  });

  test('field listing failure surfaces the HTTP error envelope', () {
    // '/field' 503s with 'fieldfail' and createmeta 503s with 'metafail':
    // both resolution legs fail, so the HTTP failure must reach the caller
    // instead of collapsing to "No fields found with name …".
    configureJira(server, token: 'fieldfail metafail');
    final result = tools.dispatch('jira_update_field', {
      'key': 'PROJ-1',
      'field': 'Story Points',
      'value': '8',
    });
    final error = errOf(result)['error'] as String;
    expect(error, contains("Failed to resolve field 'Story Points'"));
    expect(error, contains('HTTP 503'));
  });
}
