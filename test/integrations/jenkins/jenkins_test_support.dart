/// Test doubles for exercising Jenkins clients against canned HTTP responses.
library;

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';

import '../integration_test_support.dart';

export '../integration_test_support.dart' show RoutingAdapter, routeByPath;

/// A mocked [JenkinsClient] plus the [RoutingAdapter] serving its requests.
typedef MockJenkinsFixture = MockClientFixture<JenkinsClient>;

/// A mocked [JenkinsHttpClient] plus the [RoutingAdapter] serving its requests.
typedef MockHttpFixture = ({JenkinsHttpClient http, RoutingAdapter adapter});

const _testConfig = {
  'JENKINS_BASE_PATH': 'http://jenkins.example.com',
  'JENKINS_USER': 'dev',
  'JENKINS_API_TOKEN': 'token-123',
};

const _crumbBody = '{"crumb":"abc123","crumbRequestField":"Jenkins-Crumb"}';

/// Builds a [JenkinsClient] over a mocked [Dio] routed by [router].
MockJenkinsFixture mockJenkins(String Function(RequestOptions options) router) {
  final httpFix = mockHttp(
    (o) => o.path.contains('crumbIssuer') ? _crumbBody : router(o),
  );
  return (client: JenkinsClient(httpFix.http), adapter: httpFix.adapter);
}

/// Builds a [JenkinsHttpClient] over a mocked [Dio] routed by [router].
MockHttpFixture mockHttp(String Function(RequestOptions options) router) =>
    mockRoutedHttp(
      _testConfig,
      router,
      (reader, dio) => JenkinsHttpClient(reader, dio: dio),
    );
