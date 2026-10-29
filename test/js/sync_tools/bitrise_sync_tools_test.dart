import 'dart:convert';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/integrations/bitrise/bitrise_client.dart';
import 'package:dmtools/src/js/sync_tools/bitrise_sync_tools.dart';
import 'package:test/test.dart';

import '../echo_server_helper.dart';

/// Shared fixtures for the write-tools group.
late EchoServer server;
late BitriseSyncTools tools;

/// Tests for [BitriseSyncTools] — the Bitrise section of the sync tool
/// bridge (Java `Bitrise.java` @MCPTool parity, including the
/// BITRISE_ALLOW_WRITES write guard).
void main() {
  setUpAll(() {
    PropertyReader.testIsolation = true;
    BitriseClient.environment = {};
  });
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
    BitriseClient.environment = {};
  });
  _testRoutingAndConfig();
  _testWriteGuard();
  if (hasPython3()) {
    _testReadTools();
    _testWriteTools();
  }
}

Map<String, String> _config(int port) => {
      'BITRISE_TOKEN': 'brise-token',
      'BITRISE_BASE_PATH': 'http://127.0.0.1:$port/v0.1',
      'JIRA_RETRY_ENABLED': 'false',
    };

void _testRoutingAndConfig() {
  group('BitriseSyncTools routing and config', () {
    late BitriseSyncTools tools;

    setUp(() {
      PropertyReader.setOverrides({'BITRISE_TOKEN': ''});
      tools = BitriseSyncTools(PropertyReader());
    });

    tearDown(() => PropertyReader.clearOverrides());

    test('unsupported tool returns error JSON', () {
      expect(
        jsonDecode(tools.dispatch('bitrise_mystery', {})),
        {'error': 'Unsupported Bitrise tool: bitrise_mystery'},
      );
    });

    test('handlers map exposes the Java tool names', () {
      expect(tools.handlers.keys, contains('bitrise_list_builds'));
      expect(tools.handlers.keys, contains('bitrise_trigger_build'));
      expect(tools.handlers.keys, contains('bitrise_abort_build'));
      expect(tools.handlers.keys, contains('bitrise_list_build_artifacts'));
      expect(tools.handlers.keys, contains('bitrise_get_build_artifact'));
    });

    test('missing token returns not-configured error', () {
      expect(
        jsonDecode(tools.dispatch('bitrise_list_builds', {'appSlug': 'a'})),
        {'error': 'Bitrise not configured'},
      );
    });
  });
}

void _testWriteGuard() {
  group('BitriseSyncTools write guard (BITRISE_ALLOW_WRITES)', () {
    late BitriseSyncTools tools;

    setUp(() {
      PropertyReader.setOverrides(_config(0));
      tools = BitriseSyncTools(PropertyReader());
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      BitriseClient.environment = {};
    });

    test('bitrise_trigger_build is disabled when the flag is unset', () {
      final error =
          jsonDecode(tools.dispatch('bitrise_trigger_build', {'appSlug': 'a'}))
              as Map<String, dynamic>;
      expect(error['error'], contains('bitrise_trigger_build is disabled'));
      expect(error['error'], contains('BITRISE_ALLOW_WRITES'));
    });

    test('bitrise_abort_build is disabled when the flag is falsy', () {
      BitriseClient.environment = {'BITRISE_ALLOW_WRITES': 'no'};
      final error = jsonDecode(tools.dispatch(
              'bitrise_abort_build', {'appSlug': 'a', 'buildSlug': 'b'}))
          as Map<String, dynamic>;
      expect(error['error'], contains('bitrise_abort_build is disabled'));
    });

    test(
        'the guard passes with BITRISE_ALLOW_WRITES=1 (fails at HTTP, not '
        'the guard)', () {
      BitriseClient.environment = {'BITRISE_ALLOW_WRITES': '1'};
      // Port 0 is unroutable → curl error surfaces as HTTP request failed,
      // proving the call was not blocked by the guard.
      final error =
          jsonDecode(tools.dispatch('bitrise_trigger_build', {'appSlug': 'a'}))
              as Map<String, dynamic>;
      expect(error['error'], contains('HTTP request failed'));
    });
  });
}

void _testReadTools() {
  group('BitriseSyncTools read tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides(_config(server.port));
      tools = BitriseSyncTools(PropertyReader());
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      server.stop();
    });

    test('bitrise_list_builds maps filters onto the query string', () {
      final body = jsonDecode(tools.dispatch('bitrise_list_builds', {
        'appSlug': 'app-1',
        'workflowId': 'primary',
        'branch': 'main',
        'status': 'in_progress',
        'limit': 50,
      }));
      expect(body['method'], 'GET');
      expect(body['path'],
          '/v0.1/apps/app-1/builds?workflow=primary&branch=main&status=1&limit=50');
      expect(body['headers']['Authorization'], 'token brise-token');
    });

    test('bitrise_list_builds sends a bare query without filters', () {
      final body = jsonDecode(
          tools.dispatch('bitrise_list_builds', {'appSlug': 'app-1'}));
      expect(body['path'], '/v0.1/apps/app-1/builds');
    });

    test('bitrise_list_build_artifacts hits the artifacts endpoint', () {
      final body = jsonDecode(tools.dispatch('bitrise_list_build_artifacts', {
        'appSlug': 'app-1',
        'buildSlug': 'build-2',
      }));
      expect(body['method'], 'GET');
      expect(body['path'], '/v0.1/apps/app-1/builds/build-2/artifacts');
    });

    test('bitrise_get_build_artifact hits the artifact endpoint', () {
      final body = jsonDecode(tools.dispatch('bitrise_get_build_artifact', {
        'appSlug': 'app-1',
        'buildSlug': 'build-2',
        'artifactSlug': 'art-3',
      }));
      expect(body['path'], '/v0.1/apps/app-1/builds/build-2/artifacts/art-3');
    });
  });
}

void _testWriteTools() {
  group('BitriseSyncTools write tools', () {
    setUp(() async {
      server = EchoServer();
      await server.start();
      PropertyReader.setOverrides(_config(server.port));
      BitriseClient.environment = {'BITRISE_ALLOW_WRITES': '1'};
      tools = BitriseSyncTools(PropertyReader());
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      BitriseClient.environment = {};
      server.stop();
    });

    testwritetools_p1();
  });
}

void testwritetools_p1() {
  test('bitrise_trigger_build POSTs build_params and hook_info', () {
    final body = jsonDecode(tools.dispatch('bitrise_trigger_build', {
      'appSlug': 'app-1',
      'workflowId': 'primary',
      'branch': 'feature/x',
      'commitMessage': 'PROJ-1 build',
      'envVars': '[{"mapped_to":"K","value":"v"}]',
    }));
    expect(body['method'], 'POST');
    expect(body['path'], '/v0.1/apps/app-1/builds');
    final sent = jsonDecode(body['body'] as String);
    expect(sent['build_params']['workflow_id'], 'primary');
    expect(sent['build_params']['branch'], 'feature/x');
    expect(sent['build_params']['commit_message'], 'PROJ-1 build');
    expect(sent['build_params']['environments'], [
      {'mapped_to': 'K', 'value': 'v'},
    ]);
    expect(sent['hook_info'], {'type': 'bitrise'});
  });

  test('bitrise_trigger_build ignores unparsable envVars', () {
    final body = jsonDecode(tools.dispatch('bitrise_trigger_build', {
      'appSlug': 'app-1',
      'workflowId': 'primary',
      'envVars': 'not-json',
    }));
    final sent = jsonDecode(body['body'] as String);
    expect(sent['build_params'].containsKey('environments'), isFalse);
  });

  test('bitrise_abort_build POSTs the abort body with reason', () {
    final body = jsonDecode(tools.dispatch('bitrise_abort_build', {
      'appSlug': 'app-1',
      'buildSlug': 'build-2',
      'reason': 'Superseded',
    }));
    expect(body['method'], 'POST');
    expect(body['path'], '/v0.1/apps/app-1/builds/build-2/abort');
    final sent = jsonDecode(body['body'] as String);
    expect(sent['abort_reason'], 'Superseded');
    expect(sent['abort_with_success'], false);
    expect(sent['skip_notifications'], false);
  });

  test('bitrise_abort_build omits abort_reason without a reason', () {
    final body = jsonDecode(tools.dispatch(
      'bitrise_abort_build',
      {'appSlug': 'app-1', 'buildSlug': 'build-2'},
    ));
    final sent = jsonDecode(body['body'] as String);
    expect(sent.containsKey('abort_reason'), isFalse);
  });
}
