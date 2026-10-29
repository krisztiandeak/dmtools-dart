// SPDX-License-Identifier: Apache-2.0
//
// End-to-end test of the nodeCompat `fetch` surface wired in
// engine_factory: a script runs through the real bridge (wireEngine,
// nodeCompat: true) and fetches from a local HttpServer — POST body,
// request headers, response status/headers/JSON all round-trip through
// the pooled sync HTTP transport.
//
// The HTTP server runs in a SEPARATE isolate on purpose: the JS engine's
// sync host call blocks this isolate's event loop (that is the bridge
// contract), and a same-isolate server would deadlock with the curl
// fallback transport.
//
// Run: dart test test/js/fetch_compat_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dmtools/src/js/engine_factory.dart';
import 'package:dmtools/src/js/sync_http_bridge.dart';
import 'package:quickjs_runtime/src/quickjs_runtime.dart';
import 'package:test/test.dart';

/// Server isolate entry: binds, reports the port, serves until killed.
void _serve(SendPort ready) {
  HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) {
    ready.send(server.port);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/json') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'pong': body, 'ok': true}));
      } else if (req.uri.path == '/nope') {
        req.response.statusCode = 404;
        req.response.write('missing');
      } else {
        req.response.write('echo:$body');
      }
      await req.response.close();
    });
  });
}

/// Boots the pooled sync transport BEFORE any JS runs (the documented
/// boot discipline — inside a host callback the event loop is frozen and
/// Isolate.spawn cannot progress).
Future<void> _bootTransport() async {
  await SyncHttpBridge.shared.boot();
  expect(SyncHttpBridge.shared.ready, isTrue);
}

String _postScript(String url) => '''
  (function () {
    var r = fetch('$url', {
      method: 'POST',
      headers: { 'x-token': 'secret' },
      body: 'ping'
    });
    return {
      status: r.status,
      ok: r.ok,
      ct: r.headers.get('content-type'),
      data: r.json()
    };
  })()
''';

String _getScript(String url) => '''
  (function () {
    var r = fetch('$url');
    return { status: r.status, ok: r.ok, body: r.text() };
  })()
''';

void main() {
  late Isolate serverIsolate;
  late int port;
  late QuickjsRuntime rt;

  setUpAll(() async {
    final ready = ReceivePort();
    serverIsolate = await Isolate.spawn(_serve, ready.sendPort);
    port = await ready.first as int;
    await _bootTransport();
  });

  tearDownAll(() {
    serverIsolate.kill(priority: Isolate.immediate);
    SyncHttpBridge.shared.dispose();
  });

  setUp(() {
    rt = QuickjsRuntime();
    wireEngine(
      rt,
      const EngineSpec(
        context: EngineContext(jobParams: {'nodeCompat': true}),
      ),
    );
  });
  tearDown(() => rt.close());

  test('fetch POST round-trips body and headers through the sync transport',
      () {
    final result = rt.eval(_postScript('http://127.0.0.1:$port/json'),
        filename: '<fetch_e2e>');
    expect(result, isNotNull);
    final decoded = jsonDecode(result!) as Map<String, dynamic>;
    expect(decoded['status'], 200);
    expect(decoded['ok'], true);
    expect(decoded['ct'], startsWith('application/json'));
    expect(decoded['data'], {'pong': 'ping', 'ok': true});
  });

  test('non-2xx surfaces status/ok without throwing (fetch semantics)', () {
    final result = rt.eval(_getScript('http://127.0.0.1:$port/nope'),
        filename: '<fetch_e2e>');
    expect(
        jsonDecode(result!), {'status': 404, 'ok': false, 'body': 'missing'});
  });

  test('worker engines see the same surface (wireEngine path)', () {
    expect(rt.eval('typeof fetch'), '"function"');
    expect(rt.eval('typeof Response'), '"function"');
  });
}
