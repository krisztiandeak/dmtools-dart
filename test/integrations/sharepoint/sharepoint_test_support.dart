/// Test doubles for exercising SharePoint clients against canned HTTP responses.
library;

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';

import '../integration_test_support.dart';

export '../integration_test_support.dart' show RoutingAdapter, routeByPath;

/// A mocked [SharepointClient] plus the [RoutingAdapter] serving its requests.
typedef MockSharepointFixture = MockClientFixture<SharepointClient>;

/// A mocked [TeamsHttpClient] for SharePoint, plus its [RoutingAdapter].
typedef MockSharepointHttpFixture = ({
  TeamsHttpClient http,
  RoutingAdapter adapter,
});

const _testConfig = {
  'TEAMS_BASE_PATH': 'https://graph.microsoft.com/v1.0',
  'TEAMS_REFRESH_TOKEN': 'teams-access-123',
};

/// Builds a [SharepointClient] over a mocked [Dio] routed by [router].
MockSharepointFixture mockSharepoint(
  String Function(RequestOptions options) router,
) {
  final httpFix = mockSharepointHttp(router);
  return (client: SharepointClient(httpFix.http), adapter: httpFix.adapter);
}

/// Builds a [TeamsHttpClient] for SharePoint over a mocked [Dio] routed by
/// [router].
MockSharepointHttpFixture mockSharepointHttp(
  String Function(RequestOptions options) router,
) =>
    mockRoutedHttp(
      _testConfig,
      router,
      (reader, dio) => TeamsHttpClient(
        reader,
        dio: dio,
        token: _testConfig['TEAMS_REFRESH_TOKEN'],
      ),
    );
