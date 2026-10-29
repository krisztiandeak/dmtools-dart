import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

import 'ado_test_support.dart';

/// Coverage + behavior tests for [AdoClient] and [AdoHttpClient].
void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });
  tearDown(PropertyReader.clearOverrides);
  httpClientTests();
  httpClientVerbTests();
  httpClientConfigErrorTests();
  testConnectionTests();
  getWorkItemTests();
  createWorkItemTests();
  listPrsTests();
  getPrTests();
}

/// The base path injected by the fixture's config.
const _basePath = 'https://ado.example.com';

/// The Basic auth header value derived from the fixture's PAT.
final _basicAuth = 'Basic ${base64Encode(utf8.encode(':ado-pat-123'))}';

/// [AdoHttpClient]: URL building and auth headers.
void httpClientTests() {
  group('AdoHttpClient', () {
    test('builds project-scoped _apis URLs from the configured base path', () {
      final f = mockAdoHttp((o) => '{}');
      expect(
        f.http.buildUrl('wit/workitems/1'),
        '$_basePath/contoso/dmtools/_apis/wit/workitems/1',
      );
    });

    test('builds org-scoped _apis URLs', () {
      final f = mockAdoHttp((o) => '{}');
      expect(
        f.http.buildOrgUrl('connection-data'),
        '$_basePath/contoso/_apis/connection-data',
      );
    });

    test('defaults the base path to dev.azure.com when ADO_BASE_PATH is unset',
        () {
      PropertyReader.setOverrides({
        'ADO_ORGANIZATION': 'contoso',
        'ADO_PROJECT': 'dmtools',
        'ADO_PAT_TOKEN': 'ado-pat-123',
      });
      final dio = Dio()..httpClientAdapter = RoutingAdapter((o) => '{}');
      final http = AdoHttpClient(PropertyReader(), dio: dio);
      expect(
        http.buildUrl('wit/workitems'),
        'https://dev.azure.com/contoso/dmtools/_apis/wit/workitems',
      );
    });

    test('encodes the PAT as Basic base64(":" + PAT)', () {
      final f = mockAdoHttp((o) => '{}');
      expect(f.http.authHeaders['Authorization'], _basicAuth);
      expect(f.http.headers['Content-Type'], 'application/json');
    });
  });
}

/// [AdoHttpClient]: HTTP verbs, API versioning, and the patch content type.
void httpClientVerbTests() {
  group('AdoHttpClient (verbs)', () {
    test('attaches api-version=7.0 to GET requests', () async {
      final f = mockAdoHttp((o) => routeByPath({'/workitems/1': '{}'}, o));
      await f.http.get('wit/workitems/1');
      expect(f.adapter.calls.single.queryParameters['api-version'], '7.0');
    });

    test('get returns the response body', () async {
      final f = mockAdoHttp(
        (o) => routeByPath({'/workitems/1': 'GET-ITEM'}, o),
      );
      expect(await f.http.get('wit/workitems/1'), 'GET-ITEM');
      f.http.close();
    });

    test('postPatch posts with the json-patch content type', () async {
      final f = mockAdoHttp(
        (o) => routeByPath({'/\$Bug': 'CREATED'}, o),
      );
      final out = await f.http.postPatch('wit/workitems/\$Bug', body: '[]');
      expect(out, 'CREATED');
      final call = f.adapter.calls.single;
      expect(call.method, 'POST');
      expect(call.headers['Content-Type'], 'application/json-patch+json');
      expect(call.queryParameters['api-version'], '7.0');
    });
  });
}

/// [AdoHttpClient]: StateError on missing or empty configuration.
void httpClientConfigErrorTests() {
  group('AdoHttpClient (config errors)', () {
    test('throws StateError when ADO_PAT_TOKEN is missing', () {
      PropertyReader.setOverrides({
        'ADO_ORGANIZATION': 'contoso',
        'ADO_PROJECT': 'dmtools',
      });
      expect(() => AdoHttpClient(PropertyReader()), throwsStateError);
    });

    test('throws StateError when ADO_ORGANIZATION is empty', () {
      PropertyReader.setOverrides({
        'ADO_ORGANIZATION': '',
        'ADO_PROJECT': 'dmtools',
        'ADO_PAT_TOKEN': 'ado-pat-123',
      });
      expect(() => AdoHttpClient(PropertyReader()), throwsStateError);
    });

    test('throws StateError when ADO_PROJECT is missing', () {
      PropertyReader.setOverrides({
        'ADO_ORGANIZATION': 'contoso',
        'ADO_PAT_TOKEN': 'ado-pat-123',
      });
      expect(() => AdoHttpClient(PropertyReader()), throwsStateError);
    });
  });
}

/// `ado_test` — connectivity check via the Profile API
/// (`app.vssps.visualstudio.com/_apis/profile/profiles/me`).
void testConnectionTests() {
  group('AdoClient.testConnection', () {
    _profileAndFallbackTests();
    _failureTests();
  });
}

void _profileAndFallbackTests() {
  group('AdoClient.testConnection profile and fallbacks', () {
    test('returns success with the profile name and email', () async {
      final f = mockAdo(
        (o) => routeByPath({
          'app.vssps.visualstudio.com/_apis/profile/profiles/me':
              '{"displayName":"Ada","emailAddress":"ada@contoso.com"}',
        }, o),
      );
      final result = await f.client.testConnection();
      expect(result['success'], isTrue);
      expect(result['message'], 'Azure DevOps connection successful');
      expect(result['user'], 'Ada');
      expect(result['email'], 'ada@contoso.com');
      expect(f.adapter.calls.single.path,
          endsWith('app.vssps.visualstudio.com/_apis/profile/profiles/me'));
    });

    test('falls back to the projects endpoint when the profile is unreadable',
        () async {
      final f = mockAdo((o) {
        if (o.path.contains('profiles/me')) return 'garbage';
        if (o.path.endsWith('/projects')) return '[]';
        return '{}';
      });
      final result = await f.client.testConnection();
      expect(result['success'], isTrue);
      expect(result['message'] as String, contains('profile unreadable'));
    });
  });
}

void _failureTests() {
  group('AdoClient.testConnection failures', () {
    test('reports failure on a non-JSON body', () async {
      final f = mockAdo((o) => 'not-json');
      final result = await f.client.testConnection();
      expect(result['success'], isFalse);
      expect(result['error'], isNotNull);
    });

    test('profile 401 + workitemtypes OK = success', () async {
      final f = mockAdo((o) {
        if (o.path.contains('profiles/me')) throw _unauthorized();
        if (o.path.endsWith('/wit/workitemtypes')) {
          return '{"value":[{"name":"Bug"}]}';
        }
        return '{}';
      });
      final result = await f.client.testConnection();
      expect(result['success'], isTrue);
      expect(result['message'] as String, contains('profile unreadable'));
      expect(
        f.adapter.calls.any((c) => c.path.endsWith('/_apis/projects')),
        isFalse,
      );
    });

    test('profile 401 + both fallbacks fail = failure with original error',
        () async {
      final f = mockAdo((o) => throw _unauthorized());
      final result = await f.client.testConnection();
      expect(result['success'], isFalse);
      expect(result['message'], 'Azure DevOps connection failed');
      expect(result['error'] as String, contains('DioException'));
    });

    test('an empty workitemtypes body is not a success', () async {
      final f = mockAdo((o) {
        if (o.path.contains('profiles/me')) throw _unauthorized();
        if (o.path.endsWith('/wit/workitemtypes')) return '{"value":[]}';
        if (o.path.endsWith('/projects')) throw _unauthorized();
        return '{}';
      });
      final result = await f.client.testConnection();
      expect(result['success'], isFalse);
    });

    test('a healthy profile makes no fallback request', () async {
      final f = mockAdo(
        (o) => '{"displayName":"Ada","emailAddress":"ada@contoso.com"}',
      );
      await f.client.testConnection();
      expect(f.adapter.calls.length, 1);
    });
  });
}

/// A 401 error as Dio throws it for a rejected PAT.
DioException _unauthorized() => DioException(
      requestOptions: RequestOptions(path: ''),
      response: Response(
        requestOptions: RequestOptions(path: ''),
        statusCode: 401,
      ),
      type: DioExceptionType.badResponse,
    );

/// `ado_get_work_item` — GET `{org}/{project}/_apis/wit/workitems/{id}`.
void getWorkItemTests() {
  group('AdoClient.getWorkItem', () {
    test('returns the decoded work item map', () async {
      final f = mockAdo((o) => routeByPath({'/workitems/42': _itemBody}, o));
      final item = await f.client.getWorkItem(42);
      expect(item['id'], 42);
      expect(item['title'], 'Fix bug');
      final call = f.adapter.calls.single;
      expect(call.method, 'GET');
      expect(call.path, endsWith('/contoso/dmtools/_apis/wit/workitems/42'));
      expect(call.queryParameters['api-version'], '7.0');
    });
  });
}

/// `ado_create_work_item` — POST `{org}/{project}/_apis/wit/workitems/$type`.
void createWorkItemTests() {
  group('AdoClient.createWorkItem', () {
    test('POSTs a JSON Patch title op to the \$type endpoint', () async {
      final f = mockAdo(
        (o) => routeByPath({'/\$Bug': _itemBody}, o),
      );
      final result = await f.client.createWorkItem('Bug', 'Fix bug');
      expect(result['id'], 42);
      final call = f.adapter.calls.single;
      expect(call.method, 'POST');
      expect(call.path, endsWith('/contoso/dmtools/_apis/wit/workitems/\$Bug'));
      expect(call.headers['Content-Type'], 'application/json-patch+json');
      final patch = jsonDecode(call.data as String) as List;
      expect(patch, [
        {
          'op': 'add',
          'path': '/fields/System.Title',
          'value': 'Fix bug',
        },
      ]);
    });
  });
}

/// `ado_list_prs` — GET `{org}/{project}/_apis/git/pullrequests`.
void listPrsTests() {
  group('AdoClient.listPrs', () {
    test('returns the decoded list of pull requests', () async {
      final f = mockAdo((o) => routeByPath({'/pullrequests': _prListBody}, o));
      final prs = await f.client.listPrs();
      expect(prs.map((p) => p['pullRequestId']).toList(), [1, 2]);
      final call = f.adapter.calls.single;
      expect(call.method, 'GET');
      expect(call.path, endsWith('/contoso/dmtools/_apis/git/pullrequests'));
    });

    test('defaults the status filter to active', () async {
      final f = mockAdo((o) => routeByPath({'/pullrequests': _prListBody}, o));
      await f.client.listPrs();
      expect(
        f.adapter.calls.single.queryParameters['searchCriteria.status'],
        'active',
      );
    });

    test('forwards an explicit status filter', () async {
      final f = mockAdo((o) => routeByPath({'/pullrequests': _prListBody}, o));
      await f.client.listPrs('abandoned');
      expect(
        f.adapter.calls.single.queryParameters['searchCriteria.status'],
        'abandoned',
      );
    });
  });
}

/// `ado_get_pr` — GET `{org}/{project}/_apis/git/pullrequests/{id}`.
void getPrTests() {
  group('AdoClient.getPr', () {
    test('returns the decoded pull request map', () async {
      final f = mockAdo((o) => routeByPath({'/pullrequests/7': _prBody}, o));
      final pr = await f.client.getPr(7);
      expect(pr['pullRequestId'], 7);
      final call = f.adapter.calls.single;
      expect(call.method, 'GET');
      expect(call.path, endsWith('/contoso/dmtools/_apis/git/pullrequests/7'));
    });
  });
}

/// Canned `_apis/connection-data` response body.

/// Canned single work-item response body.
const _itemBody = '{"id":42,"title":"Fix bug"}';

/// Canned pull-request list response body.
const _prListBody = '[{"pullRequestId":1},{"pullRequestId":2}]';

/// Canned single pull-request response body.
const _prBody = '{"pullRequestId":7,"title":"Feature"}';
