/// Test doubles for exercising GitLab clients against canned HTTP responses.
library;

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';

import '../integration_test_support.dart';

export '../integration_test_support.dart' show RoutingAdapter, routeByPath;

/// A mocked [GitlabClient] plus the [RoutingAdapter] serving its requests.
typedef MockGitlabFixture = MockClientFixture<GitlabClient>;

/// A mocked [GitlabHttpClient] plus the [RoutingAdapter] serving its requests.
typedef MockHttpFixture = ({GitlabHttpClient http, RoutingAdapter adapter});

const _testConfig = {
  'GITLAB_BASE_PATH': 'https://gitlab.example.com',
  'GITLAB_TOKEN': 'glpat-123',
};

/// Builds a [GitlabClient] over a mocked [Dio] routed by [router].
MockGitlabFixture mockGitlab(String Function(RequestOptions options) router) {
  final httpFix = mockHttp(router);
  return (client: GitlabClient(httpFix.http), adapter: httpFix.adapter);
}

/// Builds a [GitlabHttpClient] over a mocked [Dio] routed by [router].
MockHttpFixture mockHttp(String Function(RequestOptions options) router) =>
    mockRoutedHttp(
      _testConfig,
      router,
      (reader, dio) => GitlabHttpClient(reader, dio: dio),
    );
