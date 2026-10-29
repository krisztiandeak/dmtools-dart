/// Test doubles for exercising Jira clients against canned HTTP responses.
library;

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';

import '../integration_test_support.dart';

export '../integration_test_support.dart' show RoutingAdapter, routeByPath;

/// A mocked [JiraClient] plus the [RoutingAdapter] serving its requests.
typedef MockJiraFixture = MockClientFixture<JiraClient>;

/// A mocked [JiraHttpClient] plus the [RoutingAdapter] serving its requests.
typedef MockHttpFixture = ({JiraHttpClient http, RoutingAdapter adapter});

const _testConfig = {
  'JIRA_BASE_PATH': 'https://jira.example.com',
  'JIRA_EMAIL': 'dev@example.com',
  'JIRA_API_TOKEN': 'tok-123',
};

/// Builds a [JiraClient] over a mocked [Dio] routed by [router].
MockJiraFixture mockJira(String Function(RequestOptions options) router) {
  final httpFix = mockHttp(router);
  return (client: JiraClient(httpFix.http), adapter: httpFix.adapter);
}

/// Builds a [JiraHttpClient] over a mocked [Dio] routed by [router].
MockHttpFixture mockHttp(String Function(RequestOptions options) router) =>
    mockRoutedHttp(
      _testConfig,
      router,
      (reader, dio) => JiraHttpClient(reader, dio: dio),
    );
