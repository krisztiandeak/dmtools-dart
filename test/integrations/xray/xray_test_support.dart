/// Test doubles for exercising Xray clients against canned HTTP responses.
///
/// Mirrors the Jira/TestRail test support: a [Dio] whose transport
/// ([RoutingAdapter]) answers every request from a per-request router callback
/// and records what was served, plus a [mockXray] fixture wiring a real
/// [XrayClient] (and [XrayHttpClient]) on top of it.
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';

/// A mocked [XrayClient] plus the [RoutingAdapter] serving its requests.
typedef MockXrayFixture = ({XrayClient client, RoutingAdapter adapter});

/// A mocked [XrayHttpClient] plus the [RoutingAdapter] serving its requests.
typedef MockXrayHttpFixture = ({XrayHttpClient http, RoutingAdapter adapter});

/// A canned-response [HttpClientAdapter] that records each served request.
class RoutingAdapter implements HttpClientAdapter {
  RoutingAdapter(this._router);

  final String Function(RequestOptions options) _router;

  /// Requests served so far, in call order.
  final List<RequestOptions> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    return ResponseBody.fromString(
      _router(options),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The Xray config injected for every fixture built by [mockXray].
const _testConfig = {
  'XRAY_BASE_PATH': 'https://xray.example.com',
  'XRAY_CLIENT_ID': 'client-123',
  'XRAY_CLIENT_SECRET': 'secret-456',
};

/// The Jira config injected for fixtures built by [mockXrayWithJira].
const _testJiraConfig = {
  'JIRA_BASE_PATH': 'https://jira.example.com',
  'JIRA_EMAIL': 'dev@example.com',
  'JIRA_API_TOKEN': 'tok-123',
};

/// Builds an [XrayClient] over a mocked [Dio] routed by [router].
///
/// The router maps each incoming [RequestOptions] to the response body the
/// fake server should return; served requests land in `fixture.adapter.calls`.
MockXrayFixture mockXray(String Function(RequestOptions options) router) {
  final httpFix = mockXrayHttp(router);
  return (
    client: XrayClient(httpFix.http, syncDelay: Duration.zero),
    adapter: httpFix.adapter,
  );
}

/// Builds an [XrayHttpClient] over a mocked [Dio] routed by [router].
MockXrayHttpFixture mockXrayHttp(
  String Function(RequestOptions options) router,
) {
  PropertyReader.setOverrides(_testConfig);
  final adapter = RoutingAdapter(router);
  final dio = Dio()..httpClientAdapter = adapter;
  return (
    http: XrayHttpClient(PropertyReader(), dio: dio),
    adapter: adapter,
  );
}

/// A mocked [XrayClient] plus the adapters serving its Xray and Jira
/// requests.
typedef MockXrayJiraFixture = ({
  XrayClient client,
  RoutingAdapter xray,
  RoutingAdapter jira,
});

/// Builds an [XrayClient] whose Xray and Jira transports are both mocked.
///
/// [xrayRouter] serves `/api/v2/` requests and [jiraRouter] serves
/// `/rest/api/latest/` requests; served requests land in the matching
/// adapter's `calls`. For the tools that create or search Jira issues
/// (Java's dual Jira/Xray configuration).
MockXrayJiraFixture mockXrayWithJira(
  String Function(RequestOptions options) xrayRouter,
  String Function(RequestOptions options) jiraRouter,
) {
  PropertyReader.setOverrides({..._testConfig, ..._testJiraConfig});
  final xray = RoutingAdapter(xrayRouter);
  final jira = RoutingAdapter(jiraRouter);
  final http = XrayHttpClient(
    PropertyReader(),
    dio: Dio()..httpClientAdapter = xray,
  );
  final jiraClient = JiraClient(
    JiraHttpClient(PropertyReader(), dio: Dio()..httpClientAdapter = jira),
  );
  return (
    client: XrayClient(http, jira: jiraClient, syncDelay: Duration.zero),
    xray: xray,
    jira: jira,
  );
}

/// Routes by request-path suffix, defaulting to [fallback].
///
/// Paths match with `endsWith` against the full request URL, so `'/tests'`
/// matches `.../api/v2/tests` but not `.../api/v2/test/PROJ-1/testexecutions`.
String routeByPath(
  Map<String, String> routes,
  RequestOptions options, {
  String fallback = '{}',
}) {
  for (final entry in routes.entries) {
    if (options.path.endsWith(entry.key)) return entry.value;
  }
  return fallback;
}

/// Routes GraphQL calls by sniffing the request body for a marker string.
String routeGraphQL(
  Map<String, String> markers,
  RequestOptions options, {
  String fallback = '{}',
}) {
  if (options.path.endsWith('graphql')) {
    for (final entry in markers.entries) {
      if ((options.data as String).contains(entry.key)) return entry.value;
    }
  }
  return fallback;
}
