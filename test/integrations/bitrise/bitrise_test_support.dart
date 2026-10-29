/// Test doubles for exercising Bitrise clients against canned HTTP responses.
library;

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';

import '../integration_test_support.dart';

export '../integration_test_support.dart' show RoutingAdapter, routeByPath;

/// A mocked [BitriseClient] plus the [RoutingAdapter] serving its requests.
typedef MockBitriseFixture = MockClientFixture<BitriseClient>;

/// A mocked [BitriseHttpClient] plus the [RoutingAdapter] serving its requests.
typedef MockHttpFixture = ({BitriseHttpClient http, RoutingAdapter adapter});

const _testConfig = {
  'BITRISE_BASE_PATH': 'https://bitrise.example.com/v0.1',
  'BITRISE_TOKEN': 'bitrise-123',
};

/// Builds a [BitriseClient] over a mocked [Dio] routed by [router].
MockBitriseFixture mockBitrise(String Function(RequestOptions options) router) {
  final httpFix = mockHttp(router);
  return (client: BitriseClient(httpFix.http), adapter: httpFix.adapter);
}

/// Builds a [BitriseHttpClient] over a mocked [Dio] routed by [router].
MockHttpFixture mockHttp(String Function(RequestOptions options) router) =>
    mockRoutedHttp(
      _testConfig,
      router,
      (reader, dio) => BitriseHttpClient(reader, dio: dio),
    );

/// Enables Bitrise write ops for the current test by pointing
/// [BitriseClient.environment] at a controlled map with the flag set.
void enableBitriseWrites() =>
    BitriseClient.environment = {'BITRISE_ALLOW_WRITES': '1'};
