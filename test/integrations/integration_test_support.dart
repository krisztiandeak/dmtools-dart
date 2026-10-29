/// Shared HTTP routing test doubles for integration client suites.
///
/// Provides [RoutingAdapter], [routeByPath], and [mockRoutedHttp] so each
/// integration's `*_test_support.dart` only declares its integration-specific
/// configuration and client factories.
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';

/// A mocked HTTP client [H] plus the [RoutingAdapter] serving its requests.
typedef MockHttpFixture<H> = ({H http, RoutingAdapter adapter});

/// A mocked integration client [C] plus the [RoutingAdapter] serving its
/// requests.
typedef MockClientFixture<C> = ({C client, RoutingAdapter adapter});

/// A canned-response [HttpClientAdapter] that records each served request.
class RoutingAdapter implements HttpClientAdapter {
  RoutingAdapter(
    this._router, {
    this.status = 200,
    this.contentType = 'application/json',
  });

  final String Function(RequestOptions options) _router;

  /// HTTP status every response carries.
  final int status;

  /// The `Content-Type` header every response carries.
  final String contentType;

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
      status,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Applies [config] overrides and builds an HTTP client [H] over a mocked
/// [Dio] routed by [router].
MockHttpFixture<H> mockRoutedHttp<H>(
  Map<String, String> config,
  String Function(RequestOptions options) router,
  H Function(PropertyReader reader, Dio dio) createHttp,
) {
  PropertyReader.setOverrides(config);
  final adapter = RoutingAdapter(router);
  final dio = Dio()..httpClientAdapter = adapter;
  return (http: createHttp(PropertyReader(), dio), adapter: adapter);
}

/// Routes by request-path suffix, defaulting to [fallback].
///
/// Paths match with `endsWith` against the full request URL.
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
