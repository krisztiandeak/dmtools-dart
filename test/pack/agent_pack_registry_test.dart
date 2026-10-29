import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dmtools/src/pack/agent_pack_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pack_fixtures.dart';

/// Registry refs `<agent>@<version|latest>` resolved from a flat registry
/// (env `DMTOOLS_PACK_REGISTRY`) serving `catalog.json` plus
/// `<agent>-<version>.zip` (+ `.sha256`) — split out of
/// `agent_pack_resolver_test.dart` for the loc gate (crap4dart.yaml).

late Directory packsRoot;

void main() {
  setUp(() {
    agentRoot = Directory.systemTemp.createTempSync('agents_');
    packsRoot = Directory.systemTemp.createTempSync('packs_');
  });

  tearDown(() {
    agentRoot.deleteSync(recursive: true);
    packsRoot.deleteSync(recursive: true);
  });

  group('AgentPackResolver registry refs', () {
    _registrationShapeTests();
    _explicitVersionTests();
    _latestResolutionTests();
    _unknownAgentTests();
    _availableAgentsListingTests();
    _redirectResolutionTests();
    _catalogCharsetTests();
    _malformedCatalogTests();
    _checksumTests();
  });
}

void _registrationShapeTests() {
  test('isRegistryRef requires a configured registry and the @ form', () {
    final noRegistry = AgentPackResolver(
      packsRoot: packsRoot,
      registryBaseUrl: '',
    );
    expect(
      noRegistry.isRegistryRef('my_agent@1.0.0'),
      isFalse,
      reason: 'no registry configured',
    );
    expect(noRegistry.isPack('my_agent@1.0.0'), isFalse);

    final withRegistry = AgentPackResolver(
      packsRoot: packsRoot,
      registryBaseUrl: 'http://localhost:1',
    );
    expect(withRegistry.isRegistryRef('my_agent@1.0.0'), isTrue);
    expect(withRegistry.isRegistryRef('my_agent@latest'), isTrue);
    expect(withRegistry.isPack('my_agent@latest'), isTrue);
    // Never a pack: bare names, files, paths.
    expect(withRegistry.isRegistryRef('my_agent'), isFalse);
    expect(withRegistry.isRegistryRef('my_agent.json'), isFalse);
    expect(withRegistry.isRegistryRef('./my_agent@1.0.0'), isFalse);
    expect(withRegistry.isRegistryRef('agents/my_agent@1.0.0'), isFalse);
    expect(withRegistry.isRegistryRef('@latest'), isFalse);
    expect(withRegistry.isRegistryRef('my_agent@'), isFalse);
  });
}

void _explicitVersionTests() {
  test('explicit @version downloads <agent>-<version>.zip', () async {
    final zipBytes = buildPack('my_agent', '1.2.0').readAsBytesSync();
    final server = await startRegistryServer({
      '/my_agent-1.2.0.zip': zipBytes,
      '/my_agent-1.2.0.zip.sha256': utf8.encode(
        '${sha256.convert(zipBytes)}  my_agent-1.2.0.zip',
      ),
      '/catalog.json': utf8.encode(jsonEncode({'my_agent': '1.2.0'})),
    });
    try {
      final r = AgentPackResolver(
        packsRoot: packsRoot,
        registryBaseUrl: 'http://127.0.0.1:${server.port}',
      );
      final pack = r.resolve('my_agent@1.2.0');
      expect(pack.agent, 'my_agent');
      expect(pack.version, '1.2.0');
      expect(
        File(p.join(pack.packRoot.path, 'js/main.js')).existsSync(),
        isTrue,
      );
    } finally {
      server.isolate.kill();
    }
  });
}

void _latestResolutionTests() {
  test('@latest resolves the version from catalog.json', () async {
    final zipBytes = buildPack('latest_agent', '2.0.0').readAsBytesSync();
    final server = await startRegistryServer({
      '/latest_agent-2.0.0.zip': zipBytes,
      '/latest_agent-2.0.0.zip.sha256': utf8.encode(
        '${sha256.convert(zipBytes)}',
      ),
      '/catalog.json': utf8.encode(
        jsonEncode({
          'agents': {'latest_agent': '2.0.0'}, // nested catalog shape
        }),
      ),
    });
    try {
      final r = AgentPackResolver(
        packsRoot: packsRoot,
        registryBaseUrl: 'http://127.0.0.1:${server.port}',
      );
      final pack = r.resolve('latest_agent@latest');
      expect(pack.agent, 'latest_agent');
      expect(pack.version, '2.0.0');
    } finally {
      server.isolate.kill();
    }
  });
}

void _unknownAgentTests() {
  test('@latest with an unknown agent fails naming the agent', () async {
    final server = await startRegistryServer({
      '/catalog.json': utf8.encode(jsonEncode({'other_agent': '1.0.0'})),
    });
    try {
      final r = AgentPackResolver(
        packsRoot: packsRoot,
        registryBaseUrl: 'http://127.0.0.1:${server.port}',
      );
      expect(
        () => r.resolve('unknown_agent@latest'),
        throwsA(
          isA<AgentPackException>().having(
            (e) => e.message,
            'message',
            contains('unknown_agent'),
          ),
        ),
      );
    } finally {
      server.isolate.kill();
    }
  });
}

void _availableAgentsListingTests() {
  test('unknown-agent error lists the available catalog names sorted',
      () async {
    // Java parity (dm.ai e97ff0f2): the catalog is external input — the
    // error must name what the registry actually offers, flat + nested,
    // with the 'agents' holder key excluded.
    final server = await startRegistryServer({
      '/catalog.json': utf8.encode(
        jsonEncode({
          'other': '2.0.0',
          'misc': '1.0.0',
          'agents': {'zeta': '3.0.0'},
        }),
      ),
    });
    try {
      final r = AgentPackResolver(
        packsRoot: packsRoot,
        registryBaseUrl: 'http://127.0.0.1:${server.port}',
      );
      expect(
        () => r.resolve('demo@latest'),
        throwsA(
          isA<AgentPackException>()
              .having(
                (e) => e.message,
                'message',
                contains("Agent 'demo' not found in registry catalog"),
              )
              .having(
                (e) => e.message,
                'message',
                contains('Available agents: misc, other, zeta'),
              ),
        ),
      );
    } finally {
      server.isolate.kill();
    }
  });
}

void _redirectResolutionTests() {
  test('redirecting registry base (GitHub Releases 302) resolves', () async {
    final zipBytes = buildPack('cdn_agent', '3.1.0').readAsBytesSync();
    // The server 302s every /redirect/<path> to /<path> — catalog, zip,
    // and the .sha256 sidecar all cross the redirect, like a GitHub
    // Releases download URL hopping to the signed CDN location.
    final server = await startRegistryServer({
      '/cdn_agent-3.1.0.zip': zipBytes,
      '/cdn_agent-3.1.0.zip.sha256': utf8.encode(
        '${sha256.convert(zipBytes)}  cdn_agent-3.1.0.zip',
      ),
      '/catalog.json': utf8.encode(jsonEncode({'cdn_agent': '3.1.0'})),
    });
    try {
      final r = AgentPackResolver(
        packsRoot: packsRoot,
        registryBaseUrl: 'http://127.0.0.1:${server.port}/redirect',
      );
      final pack = r.resolve('cdn_agent@latest');
      expect(pack.agent, 'cdn_agent');
      expect(pack.version, '3.1.0');
      expect(
        File(p.join(pack.packRoot.path, 'js/main.js')).existsSync(),
        isTrue,
      );
    } finally {
      server.isolate.kill();
    }
  });
}

void _catalogCharsetTests() {
  test('catalog version outside the safe charset is rejected', () async {
    final server = await startRegistryServer({
      // Traversal attempt: would escape the registry base when
      // interpolated into the download URL.
      '/catalog.json': utf8.encode(jsonEncode({'evil_agent': '../../x'})),
    });
    try {
      final r = AgentPackResolver(
        packsRoot: packsRoot,
        registryBaseUrl: 'http://127.0.0.1:${server.port}',
      );
      expect(
        () => r.resolve('evil_agent@latest'),
        throwsA(
          isA<AgentPackException>().having(
            (e) => e.message,
            'message',
            contains('Unsafe catalog version'),
          ),
        ),
      );
    } finally {
      server.isolate.kill();
    }
  });
}

void _malformedCatalogTests() {
  test('malformed catalog.json fails as AgentPackException', () async {
    final server = await startRegistryServer({
      '/catalog.json': utf8.encode('not json {'),
    });
    try {
      final r = AgentPackResolver(
        packsRoot: packsRoot,
        registryBaseUrl: 'http://127.0.0.1:${server.port}',
      );
      expect(
        () => r.resolve('my_agent@latest'),
        throwsA(
          isA<AgentPackException>().having(
            (e) => e.message,
            'message',
            contains('Malformed registry catalog'),
          ),
        ),
      );
    } finally {
      server.isolate.kill();
    }
  });
}

void _checksumTests() {
  test('@version with a mismatching .sha256 fails the checksum', () async {
    final zipBytes = buildPack('hash_agent', '1.0.0').readAsBytesSync();
    final server = await startRegistryServer({
      '/hash_agent-1.0.0.zip': zipBytes,
      '/hash_agent-1.0.0.zip.sha256': utf8.encode('${'0' * 64}  x.zip'),
    });
    try {
      final r = AgentPackResolver(
        packsRoot: packsRoot,
        registryBaseUrl: 'http://127.0.0.1:${server.port}',
      );
      expect(
        () => r.resolve('hash_agent@1.0.0'),
        throwsA(
          isA<AgentPackException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256 mismatch'),
          ),
        ),
      );
    } finally {
      server.isolate.kill();
    }
  });
}
