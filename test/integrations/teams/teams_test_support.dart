/// Test doubles for exercising Teams clients against canned HTTP responses.
library;

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';

import '../integration_test_support.dart';

export '../integration_test_support.dart' show RoutingAdapter, routeByPath;

/// A mocked [TeamsClient] plus the [RoutingAdapter] serving its requests.
typedef MockTeamsFixture = MockClientFixture<TeamsClient>;

/// A mocked [TeamsHttpClient] plus the [RoutingAdapter] serving its requests.
typedef MockTeamsHttpFixture = ({TeamsHttpClient http, RoutingAdapter adapter});

const _testConfig = {
  'TEAMS_BASE_PATH': 'https://graph.microsoft.com/v1.0',
  'TEAMS_REFRESH_TOKEN': 'teams-access-123',
};

/// Builds a [TeamsClient] over a mocked [Dio] routed by [router].
MockTeamsFixture mockTeams(
  String Function(RequestOptions options) router,
) {
  final httpFix = mockHttp(router);
  return (client: TeamsClient(httpFix.http), adapter: httpFix.adapter);
}

/// Builds a [TeamsHttpClient] over a mocked [Dio] routed by [router].
MockTeamsHttpFixture mockHttp(
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
