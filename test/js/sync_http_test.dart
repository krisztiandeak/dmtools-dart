import 'dart:convert';
import 'dart:io';

import 'package:dmtools/src/js/sync_http_bridge.dart';
import 'package:dmtools/src/js/sync_http_client.dart';
import 'package:test/test.dart';

import 'echo_server_helper.dart';

/// Unit tests for [SyncHttpClient].
///
/// `buildArgs` and `parseResponse` are tested in isolation (no network).
/// The live-HTTP group starts a Python echo server subprocess — Dart's
/// [HttpServer] runs on the event loop, which is frozen during
/// `Process.runSync('curl', …)`, so a separate process is required.
void main() {
  _testBuildArgs();
  _testBuildArgsPayloadFiles();
  _testRenderHeaderFile();
  _testParseResponse();
  _testRawByteParseResponse();
  _testIsOk();
  if (hasPython3()) {
    _testLiveHttp();
    _testSyncHttpBridge();
    _testSyncHttpBridgeRedirects();
  }
}

/// [SyncHttpBridge] — the pooled-isolate transport behind [SyncHttpClient].
///
/// Boots the bridge explicitly so these tests exercise the worker-isolate
/// path (the plain live tests above run whatever transport is ready).
void _testSyncHttpBridge() {
  group('SyncHttpBridge (pooled isolate transport)', () {
    late EchoServer server;

    setUpAll(() async {
      server = EchoServer();
      await server.start();
      await SyncHttpBridge.shared.boot();
    });

    tearDownAll(() {
      server.stop();
      SyncHttpBridge.shared.dispose();
    });

    test('boot is idempotent and ready', () async {
      expect(SyncHttpBridge.shared.ready, isTrue);
      await SyncHttpBridge.shared.boot(); // second call is a no-op
      expect(SyncHttpBridge.shared.ready, isTrue);
    });

    test('request returns status and body via the worker isolate', () {
      final resp = SyncHttpBridge.shared.request(
        'GET',
        'http://127.0.0.1:${server.port}/bridge',
      );
      expect(resp.statusCode, 200);
      expect(jsonDecode(resp.body)['path'], '/bridge');
    });

    test('request carries headers and fixed-length bodies', () {
      final resp = SyncHttpBridge.shared.request(
        'POST',
        'http://127.0.0.1:${server.port}/bridge',
        headers: {'X-Custom': 'abc123'},
        body: '{"k":1}',
      );
      final body = jsonDecode(resp.body);
      // Caller header case survives the isolate hop (no lowercasing).
      expect(body['headers']['X-Custom'], 'abc123');
      expect(body['headers']['content-length'], '7');
      expect(body['body'], '{"k":1}');
    });

    test('transport failure surfaces as status 0', () {
      final resp =
          SyncHttpBridge.shared.request('GET', 'http://127.0.0.1:1/nope');
      expect(resp.statusCode, 0);
      expect(resp.isOk, isFalse);
    });
  });
}

/// Cross-origin vs same-origin redirect header handling in [SyncHttpBridge]
/// (gh-461: Jira Cloud 303 redirects to `api.media.atlassian.com` must strip
/// `Authorization` and `X-Atlassian-Token`).
void _testSyncHttpBridgeRedirects() {
  group('SyncHttpBridge redirect header stripping (gh-461)', () {
    late EchoServer jiraServer;
    late EchoServer mediaServer;

    setUpAll(() async {
      jiraServer = EchoServer();
      mediaServer = EchoServer();
      await jiraServer.start();
      await mediaServer.start();
      await SyncHttpBridge.shared.boot();
    });

    tearDownAll(() {
      jiraServer.stop();
      mediaServer.stop();
      SyncHttpBridge.shared.dispose();
    });

    test('strips Authorization and X-Atlassian-Token on cross-origin 303', () {
      final target = Uri.encodeQueryComponent(
        'http://127.0.0.1:${mediaServer.port}/media/file/1/binary',
      );
      final resp = SyncHttpBridge.shared.request(
        'GET',
        'http://127.0.0.1:${jiraServer.port}/rest/api/2/attachment/content/1'
            '?to=$target',
        headers: {
          'Authorization': 'Basic dXNlcjp0b2s=',
          'X-Atlassian-Token': 'nocheck',
        },
        followRedirects: true,
      );
      expect(resp.statusCode, 200);
      expect(resp.body, 'CDN-binary-bytes');
    });

    test('keeps Authorization on same-origin redirect', () {
      final target = Uri.encodeQueryComponent(
        'http://127.0.0.1:${jiraServer.port}/same-origin-redir-target',
      );
      final resp = SyncHttpBridge.shared.request(
        'GET',
        'http://127.0.0.1:${jiraServer.port}/rest/api/2/attachment/content/1'
            '?to=$target',
        headers: {'Authorization': 'Basic dXNlcjp0b2s='},
        followRedirects: true,
      );
      expect(resp.statusCode, 200);
      expect(resp.body, 'same-origin-bytes');
    });
  });
}

void _testBuildArgs() {
  group('SyncHttpClient.buildArgs', () {
    test('GET: method, URL last, -w flag present', () {
      final args = SyncHttpClient.buildArgs('GET', 'http://ex.com/api');
      expect(args, containsAll(['-s', '-X', 'GET']));
      expect(args[args.indexOf('-w') + 1], '\n%{http_code}');
      expect(args.last, 'http://ex.com/api');
    });

    test('carries connect and total timeouts', () {
      final args = SyncHttpClient.buildArgs('GET', 'http://ex.com/api');
      expect(args[args.indexOf('--connect-timeout') + 1], '10');
      expect(args[args.indexOf('--max-time') + 1], '60');
    });

    test('followRedirects opt-in adds -L with a redirect cap', () {
      final args = SyncHttpClient.buildArgs(
        'GET',
        'http://ex.com/api',
        followRedirects: true,
      );
      expect(args, contains('-L'));
      expect(args[args.indexOf('--max-redirs') + 1], '5');
    });

    test('redirect following stays off by default (curl -s parity)', () {
      final args = SyncHttpClient.buildArgs('GET', 'http://ex.com/api');
      expect(args, isNot(contains('-L')));
      expect(args, isNot(contains('--location')));
      expect(args, isNot(contains('--max-redirs')));
    });
  });
}

/// `SyncHttpClient.buildArgs` — body/header file flags and URL placement
/// (split out of [_testBuildArgs] for the loc gate).
void _testBuildArgsPayloadFiles() {
  group('SyncHttpClient.buildArgs payload files', () {
    test('body referenced via --data-binary @file, never inline', () {
      final args = SyncHttpClient.buildArgs(
        'POST',
        'http://ex.com',
        bodyFile: '/tmp/body.json',
      );
      expect(args[args.indexOf('--data-binary') + 1], '@/tmp/body.json');
      expect(args, isNot(contains('{"k":"v"}')));
      expect(args[args.indexOf('-X') + 1], 'POST');
    });

    test('headers referenced via -H @file, secrets never inline', () {
      final args = SyncHttpClient.buildArgs(
        'GET',
        'http://ex.com',
        headerFile: '/tmp/headers.txt',
      );
      expect(args[args.indexOf('-H') + 1], '@/tmp/headers.txt');
      expect(args, isNot(contains('Bearer tok')));
    });

    test('URL is always the final argument', () {
      final args = SyncHttpClient.buildArgs(
        'POST',
        'http://ex.com/p',
        headerFile: '/tmp/h',
        bodyFile: '/tmp/b',
      );
      expect(args.last, 'http://ex.com/p');
    });

    test('no header/body files omits -H and --data-binary flags', () {
      final args = SyncHttpClient.buildArgs('DELETE', 'http://ex.com');
      expect(args.contains('-H'), isFalse);
      expect(args.contains('--data-binary'), isFalse);
    });
  });
}

/// [SyncHttpClient.renderHeaderFile] — the `-H @file` payload format.
void _testRenderHeaderFile() {
  test('renderHeaderFile writes one "Key: Value" line per header', () {
    final rendered = SyncHttpClient.renderHeaderFile({
      'Authorization': 'Bearer tok',
      'Accept': 'json',
    });
    expect(rendered, 'Authorization: Bearer tok\nAccept: json');
  });
}

void _testParseResponse() {
  group('SyncHttpClient.parseResponse', () {
    test('extracts status code from trailing line', () {
      final resp = SyncHttpClient.parseResponse(_result('{"ok":true}\n200'));
      expect(resp.statusCode, 200);
      expect(resp.body, '{"ok":true}');
    });

    test('preserves newlines inside response body', () {
      final output = '{"a":1,\n"b":2}\n200';
      final resp = SyncHttpClient.parseResponse(_result(output));
      expect(resp.statusCode, 200);
      expect(resp.body, '{"a":1,\n"b":2}');
    });

    test('empty body with 204', () {
      final resp = SyncHttpClient.parseResponse(_result('\n204'));
      expect(resp.statusCode, 204);
      expect(resp.body, isEmpty);
    });

    test('connection failure (000) returns stderr as body', () {
      final resp = SyncHttpClient.parseResponse(
        _result('\n000', stderr: 'Connection refused', exitCode: 7),
      );
      expect(resp.statusCode, 0);
      expect(resp.body, 'curl exit 7: Connection refused');
    });

    test('curl exit 28 (timeout) surfaces a distinct timeout error', () {
      final resp = SyncHttpClient.parseResponse(
        _result('\n000', stderr: 'Operation timed out', exitCode: 28),
      );
      expect(resp.statusCode, 0);
      expect(resp.body, contains('timed out'));
      expect(resp.body, contains('--max-time'));
    });
  });
}

/// The byte-mode twin (`_parseRawResponse`): raw `List<int>` stdout is what
/// the default curl transport feeds [parseResponse].
void _testRawByteParseResponse() {
  group('SyncHttpClient.parseResponse: raw byte stdout', () {
    test('splits the trailing status line off the raw bytes', () {
      final bytes = utf8.encode('<h1>Hi</h1>\n200');
      final resp = SyncHttpClient.parseResponse(_rawResult(bytes));
      expect(resp.statusCode, 200);
      expect(resp.body, '<h1>Hi</h1>');
      expect(resp.bodyBytes, utf8.encode('<h1>Hi</h1>'));
    });

    test('decodes non-ASCII body bytes without a charset', () {
      final bytes = utf8.encode('{"a":"ü"}\n201');
      final resp = SyncHttpClient.parseResponse(_rawResult(bytes));
      expect(resp.statusCode, 201);
      expect(resp.body, '{"a":"ü"}');
    });

    test('no newline separator surfaces the curl exit code', () {
      final resp = SyncHttpClient.parseResponse(
        _rawResult(utf8.encode('garbage'), exitCode: 7),
      );
      expect(resp.statusCode, 0);
      expect(resp.body, 'curl exit 7');
    });

    test('status 000 reports stderr as the diagnostic', () {
      final resp = SyncHttpClient.parseResponse(_rawResult(
        utf8.encode('\n000'),
        stderr: 'Connection refused',
        exitCode: 7,
      ));
      expect(resp.statusCode, 0);
      expect(resp.body, 'curl exit 7: Connection refused');
    });

    test('status 000 with empty stderr falls back to the body', () {
      final resp = SyncHttpClient.parseResponse(
        _rawResult(utf8.encode('boom\n000'), exitCode: 7),
      );
      expect(resp.statusCode, 0);
      expect(resp.body, 'curl exit 7: boom');
    });

    test('non-UTF-8 body bytes survive as bytes (allowMalformed)', () {
      final bytes = <int>[0xff, 0xfe, 0x0a, 0x32, 0x30, 0x30];
      final resp = SyncHttpClient.parseResponse(_rawResult(bytes));
      expect(resp.statusCode, 200);
      expect(resp.bodyBytes, <int>[0xff, 0xfe]);
    });
  });
}

/// A [ProcessResult] whose stdout is raw bytes (the default curl transport).
ProcessResult _rawResult(
  List<int> stdout, {
  String stderr = '',
  int exitCode = 0,
}) =>
    ProcessResult(0, exitCode, stdout, stderr);

void _testIsOk() {
  group('SyncHttpResponse.isOk', () {
    test('2xx is true, everything else false', () {
      expect(SyncHttpResponse(200, '').isOk, isTrue);
      expect(SyncHttpResponse(201, '').isOk, isTrue);
      expect(SyncHttpResponse(299, '').isOk, isTrue);
      expect(SyncHttpResponse(300, '').isOk, isFalse);
      expect(SyncHttpResponse(404, '').isOk, isFalse);
      expect(SyncHttpResponse(0, '').isOk, isFalse);
    });
  });
}

void _testLiveHttp() {
  _testLiveMethods();
  _testLiveHeadersAndFailures();
}

void _testLiveMethods() {
  group('SyncHttpClient live HTTP methods', () {
    late EchoServer server;

    setUp(() async {
      server = EchoServer();
      await server.start();
    });

    tearDown(() => server.stop());

    test('GET returns echoed response', () {
      final resp = SyncHttpClient.get('http://127.0.0.1:${server.port}/api/t');
      expect(resp.statusCode, 200);
      final body = jsonDecode(resp.body);
      expect(body['method'], 'GET');
      expect(body['path'], '/api/t');
    });

    test('POST sends body to server', () {
      final resp = SyncHttpClient.post(
        'http://127.0.0.1:${server.port}/submit',
        headers: {'Content-Type': 'application/json'},
        body: '{"hello":"world"}',
      );
      expect(resp.statusCode, 200);
      final body = jsonDecode(resp.body);
      expect(body['method'], 'POST');
      expect(body['body'], '{"hello":"world"}');
    });

    test('PUT sends body', () {
      final resp = SyncHttpClient.put(
        'http://127.0.0.1:${server.port}/update',
        body: '{"k":1}',
      );
      final body = jsonDecode(resp.body);
      expect(body['method'], 'PUT');
    });

    test('DELETE works', () {
      final resp = SyncHttpClient.delete('http://127.0.0.1:${server.port}/rm');
      final body = jsonDecode(resp.body);
      expect(body['method'], 'DELETE');
    });
  });
}

void _testLiveHeadersAndFailures() {
  group('SyncHttpClient live HTTP headers and failures', () {
    late EchoServer server;

    setUp(() async {
      server = EchoServer();
      await server.start();
    });

    tearDown(() => server.stop());

    test('custom headers reach the server', () {
      final resp = SyncHttpClient.get(
        'http://127.0.0.1:${server.port}/api',
        headers: {'X-Custom': 'abc123'},
      );
      final body = jsonDecode(resp.body);
      expect(body['headers']['X-Custom'], 'abc123');
    });

    test('connection failure yields status 0', () {
      // Port 1 requires root — very unlikely to have a listener.
      final resp = SyncHttpClient.get('http://127.0.0.1:1/nope');
      expect(resp.statusCode, 0);
      expect(resp.isOk, isFalse);
    });

    test('large body (200KB) avoids the argv size limit via temp file', () {
      final big = 'x' * 200 * 1024;
      final resp = SyncHttpClient.post(
        'http://127.0.0.1:${server.port}/big',
        body: big,
      );
      expect(resp.statusCode, 200);
      final body = jsonDecode(resp.body);
      expect((body['body'] as String).length, 200 * 1024);
    });
  });
}

ProcessResult _result(String stdout, {String stderr = '', int exitCode = 0}) =>
    ProcessResult(0, exitCode, stdout, stderr);
