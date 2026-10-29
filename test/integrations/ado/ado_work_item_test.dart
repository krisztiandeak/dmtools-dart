import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

import 'ado_test_support.dart';

/// Work-item tests: the `wit/workitems` client methods, tool-catalog
/// shape, and executor routing (update/get/list, types, revisions,
/// comments, links).
void main() {
  tearDown(PropertyReader.clearOverrides);
  updateWorkItemTests();
  getWorkItemsTests();
  listWorkItemsTests();
  _listWorkItemsQueryTests();
  _wiqlLinkQueryTests();
  _createWorkItemProjectTests();
  getWorkItemTypesTests();
  getWorkItemRevisionsTests();
  getWorkItemCommentsTests();
  addWorkItemCommentTests();
  createWorkItemLinkTests();
  workItemCatalogRegistrationTests();
  workItemCatalogParamShapeTests();
  workItemUpdateExecutorTests();
  workItemReadExecutorTests();
  workItemWriteExecutorTests();
}

/// The configured project injected by the fixture.
const _project = 'dmtools';

/// Canned updated work item.
const _updatedItem = '{"id":42,"rev":3}';

/// Canned work-item array.
const _itemArray = '[{"id":1},{"id":2}]';

/// Canned work-item-type array.
const _typeArray = '[{"name":"Bug"},{"name":"Task"}]';

/// Canned revision array.
const _revArray = '[{"rev":1},{"rev":2}]';

/// Canned comment array.
const _commentArray = '[{"id":1,"text":"looks good"}]';

/// Canned created comment object.
const _comment = '{"id":1,"text":"nice"}';

/// Canned created link object.
const _link = '{"id":1,"rev":2}';

/// `ado_update_work_item` — PATCH with JSON-Patch field ops.
void updateWorkItemTests() {
  group('AdoClient.updateWorkItem', () {
    test('PATCHes one add-op per field with the json-patch content type',
        () async {
      final f = mockAdo((o) => routeByPath({'/workitems/42': _updatedItem}, o));
      final result = await f.client.updateWorkItem(
        42,
        <String, dynamic>{'System.Title': 'New', 'System.State': 'Active'},
      );
      expect(result['rev'], 3);
      final call = f.adapter.calls.single;
      expect(call.method, 'PATCH');
      expect(call.path, endsWith('/contoso/dmtools/_apis/wit/workitems/42'));
      expect(call.headers['Content-Type'], 'application/json-patch+json');
      final ops = jsonDecode(call.data as String) as List;
      expect(ops, [
        {'op': 'add', 'path': '/fields/System.Title', 'value': 'New'},
        {'op': 'add', 'path': '/fields/System.State', 'value': 'Active'},
      ]);
    });
  });
}

/// `ado_get_work_items` — GET `wit/workitems?ids=`.
void getWorkItemsTests() {
  group('AdoClient.getWorkItems', () {
    test('GETs the ids query and decodes the list', () async {
      final f = mockAdo((o) => routeByPath({'/workitems': _itemArray}, o));
      final items = await f.client.getWorkItems([1, 2]);
      expect(items.map((i) => i['id']).toList(), [1, 2]);
      final call = f.adapter.calls.single;
      expect(call.method, 'GET');
      expect(call.queryParameters['ids'], '1,2');
      expect(call.queryParameters['api-version'], '7.0');
    });
  });
}

/// `ado_list_work_items` — POST `wit/wiql`, then batch `wit/workitems`.
void listWorkItemsTests() {
  group('AdoClient.listWorkItems', () {
    test('POSTs WIQL then batch-fetches full work items', () async {
      final f = mockAdo(_wiqlRouter);
      final items = await f.client.listWorkItems('Select [System.Id]');
      expect(items.map((i) => i['id']).toList(), [1, 2]);
      expect(items.first['fields'], isNotNull,
          reason: 'must return full work items, not WIQL id stubs');
      final calls = f.adapter.calls;
      expect(calls, hasLength(2));
      expect(calls.first.method, 'POST');
      expect(calls.first.path, endsWith('/contoso/dmtools/_apis/wit/wiql'));
      expect(jsonDecode(calls.first.data as String),
          {'query': 'Select [System.Id]'});
      expect(calls.last.method, 'GET');
      expect(calls.last.path, endsWith('/contoso/dmtools/_apis/wit/workitems'));
      expect(calls.last.queryParameters['ids'], '1,2');
      expect(calls.last.queryParameters[r'$expand'], 'relations');
    });
  });
}

void _wiqlLinkQueryTests() {
  group('list work items WorkItemLinks handling', () {
    test('reads target ids from workItemRelations (WorkItemLinks queries)',
        () async {
      final f = mockAdo((o) {
        if (o.path.endsWith('/wiql')) {
          return jsonEncode({
            'queryType': 'tree',
            'workItemRelations': [
              {
                'rel': null,
                'source': null,
                'target': {'id': 7}
              },
              {
                'rel': 'System.LinkTypes.Hierarchy-Forward',
                'source': {'id': 7},
                'target': {'id': 8},
              },
            ],
          });
        }
        final ids = (o.queryParameters['ids'] as String).split(',');
        return jsonEncode({
          'value': [
            for (final id in ids) {'id': int.parse(id)}
          ],
        });
      });
      final items = await f.client.listWorkItems('FROM WorkItemLinks');
      // Target-only per the PR spec: the anchor row (rel null, id 7) is skipped.
      expect(items.map((i) => i['id']).toList(), [8]);
      expect(f.adapter.calls.last.queryParameters['ids'], '8');
    });
  });
}

void _createWorkItemProjectTests() {
  group('AdoClient.workItemOps.createWorkItemWithParent project argument', () {
    test('rejects a numeric project id with a clear error', () async {
      final f = mockAdo((_) => '{}');
      await expectLater(
        f.client.workItemOps.createWorkItemWithParent(
          project: '879',
          workItemType: 'Task',
          title: 't',
        ),
        throwsA(isA<ArgumentError>().having(
            (e) => e.message.toString(), 'message', contains('numeric id'))),
      );
      expect(f.adapter.calls, isEmpty);
    });
  });
}

void _listWorkItemsQueryTests() {
  group('list work items WIQL handling', () {
    test('requests explicit fields instead of \$expand when given', () async {
      final f = mockAdo(_wiqlRouter);
      await f.client
          .listWorkItems('Select [System.Id]', fields: ['System.Title']);
      final detail = f.adapter.calls.last;
      expect(detail.queryParameters['fields'], 'System.Title');
      expect(detail.queryParameters.containsKey(r'$expand'), isFalse);
    });

    test('expands a bare WHERE fragment into a full WIQL statement', () async {
      final f = mockAdo(_wiqlRouter);
      await f.client.listWorkItems("[System.State] = 'Active'");
      expect(jsonDecode(f.adapter.calls.first.data as String), {
        'query':
            "SELECT [System.Id] FROM WorkItems WHERE [System.State] = 'Active'"
      });
    });

    test('sends SELECT statements byte for byte (any case, leading space)',
        () async {
      final f = mockAdo(_wiqlRouter);
      await f.client.listWorkItems('  select [System.Id] FROM WorkItems');
      expect(jsonDecode(f.adapter.calls.first.data as String),
          {'query': '  select [System.Id] FROM WorkItems'});
    });

    test('treats a field starting with "select" as a WHERE fragment', () async {
      final f = mockAdo(_wiqlRouter);
      await f.client.listWorkItems('selection = 1');
      expect(jsonDecode(f.adapter.calls.first.data as String),
          {'query': 'SELECT [System.Id] FROM WorkItems WHERE selection = 1'});
    });

    test('expandWiql passes null and blank input through', () {
      expect(expandWiql(null), isNull);
      expect(expandWiql('   '), '   ');
    });

    test('splits ids into batches of 200', () async {
      final f = mockAdo(_wiqlRouter);
      final items =
          await f.client.listWorkItems('Select [System.Id] FROM 201 stubs');
      expect(items, hasLength(201));
      final detailCalls =
          f.adapter.calls.where((c) => c.method == 'GET').toList();
      expect(detailCalls, hasLength(2));
      expect(
          detailCalls.first.queryParameters['ids'].split(','), hasLength(200));
      expect(detailCalls.last.queryParameters['ids'].split(','), hasLength(1));
    });
  });
}

/// Serves the real ADO response shapes: the WIQL POST answers id/url
/// stubs wrapped in `workItems`, the detail GET answers `{count, value}`.
String _wiqlRouter(RequestOptions o) {
  if (o.path.endsWith('/wiql')) {
    final query = o.data is String
        ? (jsonDecode(o.data as String) as Map)['query'] as String? ?? ''
        : '';
    final count = query.contains('201 stubs') ? 201 : 2;
    return jsonEncode({
      'queryType': 'flat',
      'workItems': [
        for (var i = 1; i <= count; i++) {'id': i, 'url': 'stub://$i'},
      ],
    });
  }
  final ids = (o.queryParameters['ids'] as String).split(',').map(int.parse);
  return jsonEncode({
    'count': ids.length,
    'value': [
      for (final id in ids)
        {
          'id': id,
          'fields': {'System.Id': id}
        },
    ],
  });
}

/// `ado_get_work_item_types` — GET `wit/workitemtypes`.
void getWorkItemTypesTests() {
  group('AdoClient.getWorkItemTypes', () {
    test('GETs workitemtypes and decodes the list', () async {
      final f = mockAdo((o) => routeByPath({'/workitemtypes': _typeArray}, o));
      final types = await f.client.getWorkItemTypes(_project);
      expect(types.map((t) => t['name']).toList(), ['Bug', 'Task']);
      final call = f.adapter.calls.single;
      expect(call.method, 'GET');
      expect(call.path, endsWith('/contoso/dmtools/_apis/wit/workitemtypes'));
    });
  });
}

/// `ado_get_work_item_revisions` — GET `wit/workitems/{id}/revisions`.
void getWorkItemRevisionsTests() {
  group('AdoClient.getWorkItemRevisions', () {
    test('GETs revisions and decodes the list', () async {
      final f = mockAdo(
        (o) => routeByPath({'/workitems/42/revisions': _revArray}, o),
      );
      final revs = await f.client.getWorkItemRevisions(42);
      expect(revs.map((r) => r['rev']).toList(), [1, 2]);
      final call = f.adapter.calls.single;
      expect(call.method, 'GET');
      expect(
        call.path,
        endsWith('/contoso/dmtools/_apis/wit/workitems/42/revisions'),
      );
    });
  });
}

/// `ado_get_work_item_comments` — GET `wit/workitems/{id}/comments`.
void getWorkItemCommentsTests() {
  group('AdoClient.getWorkItemComments', () {
    test('GETs comments and decodes the list', () async {
      final f = mockAdo((o) => routeByPath({'/comments': _commentArray}, o));
      final comments = await f.client.getWorkItemComments(42);
      expect(comments.single['text'], 'looks good');
      final call = f.adapter.calls.single;
      expect(call.method, 'GET');
      expect(
        call.path,
        endsWith('/contoso/dmtools/_apis/wit/workitems/42/comments'),
      );
    });
  });
}

/// `ado_add_work_item_comment` — POST `wit/workitems/{id}/comments`.
void addWorkItemCommentTests() {
  group('AdoClient.addWorkItemComment', () {
    test('POSTs a comment and decodes the object', () async {
      final f = mockAdo((o) => o.method == 'POST' ? _comment : '[]');
      final result = await f.client.addWorkItemComment(42, 'nice');
      expect(result['text'], 'nice');
      final call = f.adapter.calls.single;
      expect(call.method, 'POST');
      expect(
        call.path,
        endsWith('/contoso/dmtools/_apis/wit/workitems/42/comments'),
      );
      expect(jsonDecode(call.data as String), {'text': 'nice'});
    });
  });
}

/// `ado_create_work_item_link` — POST `wit/workitems/{sourceId}/links`.
void createWorkItemLinkTests() {
  group('AdoClient.createWorkItemLink', () {
    test('POSTs a JSON-Patch relation add and decodes the object', () async {
      const linkType = 'System.LinkTypes.Hierarchy-Forward';
      final f = mockAdo((o) => o.method == 'POST' ? _link : '{}');
      final result = await f.client.createWorkItemLink(1, 2, linkType);
      expect(result['id'], 1);
      final call = f.adapter.calls.single;
      expect(call.method, 'POST');
      expect(call.headers['Content-Type'], 'application/json-patch+json');
      expect(
          call.path, endsWith('/contoso/dmtools/_apis/wit/workitems/1/links'));
      final sent = jsonDecode(call.data as String) as List<dynamic>;
      expect(sent.single['op'], 'add');
      expect(sent.single['path'], '/relations/-');
      final value = sent.single['value'] as Map<String, dynamic>;
      expect(value['rel'], linkType);
      expect(value['url'], endsWith('/_apis/wit/workitems/2'));
    });
  });
}

/// Looks up a registered tool by name.
ToolDefinition toolNamed(String name) =>
    adoTools().firstWhere((t) => t.name == name);

/// Tool-catalog registration for the work-item tools.
void workItemCatalogRegistrationTests() {
  group('adoTools catalog (work items)', () {
    test('registers all eight work-item tools', () {
      final names = adoTools().map((t) => t.name).toSet();
      for (final name in [
        'ado_update_work_item',
        'ado_get_work_item_revisions',
        'ado_create_work_item_link',
        'ado_get_work_items',
        'ado_list_work_items',
        'ado_get_work_item_types',
        'ado_get_work_item_comments',
        'ado_add_work_item_comment',
      ]) {
        expect(names, contains(name));
      }
    });
  });
}

/// Tool-catalog parameter shapes for the work-item tools.
void workItemCatalogParamShapeTests() {
  group('adoTools catalog (work items)', () {
    test('ado_update_work_item declares id and fields', () {
      final tool = toolNamed('ado_update_work_item');
      expect(tool.params.map((p) => p.name), ['id', 'fields']);
      expect(tool.params.first.type, 'number');
      expect(tool.params.last.type, 'object');
    });

    test('ado_get_work_items declares a required ids array', () {
      final tool = toolNamed('ado_get_work_items');
      expect(tool.params.single.name, 'ids');
      expect(tool.params.single.type, 'array');
    });

    test('ado_list_work_items declares wiql and optional fields', () {
      final tool = toolNamed('ado_list_work_items');
      expect(tool.params.map((p) => p.name), ['wiql', 'fields']);
      expect(tool.aliases, ['ado_search_by_wiql', 'tracker_search']);
    });

    test('ado_get_work_item_revisions declares a numeric id', () {
      final tool = toolNamed('ado_get_work_item_revisions');
      expect(tool.params.single.name, 'id');
      expect(tool.params.single.type, 'number');
    });

    test('ado_get_work_item_comments declares a numeric id', () {
      final tool = toolNamed('ado_get_work_item_comments');
      expect(tool.params.single.name, 'id');
      expect(tool.params.single.type, 'number');
    });

    test('ado_add_work_item_comment declares id and comment (text alias)', () {
      final tool = toolNamed('ado_add_work_item_comment');
      expect(tool.params.map((p) => p.name), ['id', 'comment', 'format']);
      expect(tool.params[1].aliases, ['text', 'body']);
    });

    test('ado_create_work_item_link declares numeric ids and linkType', () {
      final tool = toolNamed('ado_create_work_item_link');
      expect(
        tool.params.map((p) => p.name),
        ['sourceId', 'targetId', 'linkType'],
      );
      expect(tool.params[0].type, 'number');
      expect(tool.params[1].type, 'number');
    });
  });
}

/// Serves `[]` for the list GETs and `{}` for mutations; the WIQL search
/// is a POST that answers a list.
String _workItemRouter(RequestOptions o) {
  if (o.path.endsWith('/wiql')) return _itemArray;
  return o.method == 'GET' ? '[]' : '{}';
}

/// [AdoToolExecutor.execute] routing for the update tool.
void workItemUpdateExecutorTests() {
  late _WorkItemFixture f;

  group('AdoToolExecutor.execute (work items)', () {
    setUp(() => f = _workItemFixture());

    test('routes ado_update_work_item with id and fields', () async {
      await f.executor.execute('ado_update_work_item', {
        'id': 42,
        'fields': <String, dynamic>{'System.Title': 'New'},
      });
      expect(f.spy.calls.single, 'updateWorkItem:42:System.Title=New');
    });
  });
}

/// [AdoToolExecutor.execute] routing for the read tools.
void workItemReadExecutorTests() {
  late _WorkItemFixture f;

  group('AdoToolExecutor.execute (work items)', () {
    setUp(() => f = _workItemFixture());

    test('routes ado_get_work_items with an int list', () async {
      await f.executor.execute('ado_get_work_items', {
        'ids': [1, 2]
      });
      expect(f.spy.calls.single, 'getWorkItems:1,2');
    });

    test('routes ado_list_work_items with the wiql query', () async {
      await f.executor.execute('ado_list_work_items', {'wiql': 'Select [Id]'});
      expect(f.spy.calls.single, 'listWorkItems:Select [Id]');
    });

    test('routes ado_get_work_item_types with the project', () async {
      await f.executor.execute('ado_get_work_item_types', {'project': 'p'});
      expect(f.spy.calls.single, 'getWorkItemTypes:p');
    });

    test('routes ado_get_work_item_revisions with id', () async {
      await f.executor.execute('ado_get_work_item_revisions', {'id': 42});
      expect(f.spy.calls.single, 'getWorkItemRevisions:42');
    });

    test('routes ado_get_work_item_comments with id', () async {
      await f.executor.execute('ado_get_work_item_comments', {'id': 42});
      expect(f.spy.calls.single, 'getWorkItemComments:42');
    });
  });
}

/// [AdoToolExecutor.execute] routing for the comment and link tools.
void workItemWriteExecutorTests() {
  late _WorkItemFixture f;

  group('AdoToolExecutor.execute (work items)', () {
    setUp(() => f = _workItemFixture());

    test('routes ado_add_work_item_comment with id and text', () async {
      await f.executor
          .execute('ado_add_work_item_comment', {'id': 42, 'text': 'nice'});
      expect(f.spy.calls.single, 'addWorkItemComment:42:nice');
    });

    test('routes ado_create_work_item_link with numeric ids', () async {
      await f.executor.execute('ado_create_work_item_link', {
        'sourceId': 1,
        'targetId': 2,
        'linkType': 'rel',
      });
      expect(f.spy.calls.single, 'createWorkItemLink:1:2:rel');
    });

    test('parses numeric-string ids on create_work_item_link', () async {
      await f.executor.execute('ado_create_work_item_link', {
        'sourceId': '1',
        'targetId': '2',
        'linkType': 'rel',
      });
      expect(f.spy.calls.single, 'createWorkItemLink:1:2:rel');
    });
  });
}

/// A spy client plus the executor bound to it.
typedef _WorkItemFixture = ({AdoToolExecutor executor, _WorkItemSpy spy});

/// Builds a [_WorkItemSpy] over the mocked transport and wraps it.
_WorkItemFixture _workItemFixture() {
  final spy = _WorkItemSpy(mockAdoHttp(_workItemRouter).http);
  return (executor: AdoToolExecutor(spy), spy: spy);
}

/// Records every dispatched work-item call then delegates to the real client.
class _WorkItemSpy extends AdoClient {
  _WorkItemSpy(super.http);

  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> updateWorkItem(
    int id,
    Map<String, dynamic> fields,
  ) {
    final summary = fields.entries.map((e) => '${e.key}=${e.value}').join(',');
    calls.add('updateWorkItem:$id:$summary');
    return super.updateWorkItem(id, fields);
  }

  @override
  Future<List<Map<String, dynamic>>> getWorkItems(List<int> ids,
      {List<String>? fields}) {
    calls.add('getWorkItems:${ids.join(',')}');
    return super.getWorkItems(ids, fields: fields);
  }

  @override
  Future<List<Map<String, dynamic>>> listWorkItems(String wiql,
      {List<String>? fields}) {
    calls.add('listWorkItems:$wiql');
    return super.listWorkItems(wiql, fields: fields);
  }

  @override
  Future<List<Map<String, dynamic>>> getWorkItemTypes(String project) {
    calls.add('getWorkItemTypes:$project');
    return super.getWorkItemTypes(project);
  }

  @override
  Future<List<Map<String, dynamic>>> getWorkItemRevisions(int id) {
    calls.add('getWorkItemRevisions:$id');
    return super.getWorkItemRevisions(id);
  }

  @override
  Future<List<Map<String, dynamic>>> getWorkItemComments(int id) {
    calls.add('getWorkItemComments:$id');
    return super.getWorkItemComments(id);
  }

  @override
  Future<Map<String, dynamic>> addWorkItemComment(
    int id,
    String text, {
    String? format,
  }) {
    calls.add('addWorkItemComment:$id:$text');
    return super.addWorkItemComment(id, text, format: format);
  }

  @override
  Future<Map<String, dynamic>> createWorkItemLink(
    int sourceId,
    int targetId,
    String linkType,
  ) {
    calls.add('createWorkItemLink:$sourceId:$targetId:$linkType');
    return super.createWorkItemLink(sourceId, targetId, linkType);
  }
}
