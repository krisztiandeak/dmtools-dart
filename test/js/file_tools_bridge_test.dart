/// JS-bridge `file_list`/`file_exists`/`file_write` parity with Java
/// `FileTools`
/// (epam/dm.ai 3fa210e6, #635): the tools the agents suite relies on,
/// exposed through the same `executeToolViaJava` path the JS side uses.
///
/// Java `FileTools.listFiles` returns `{"entries": [absolute paths,
/// sorted]}`; `fileExists` returns a boolean (false for paths outside the
/// sandbox). The Dart bridge answers both as JSON strings. Note: Java
/// `listFiles` returns `null` for unlistable dirs; the Dart bridge returns
/// the `{"error": …}` envelope instead — a deliberate Dart convention.
///
/// gh-365: the whole bridge `file_*` family (every entry of
/// `ToolBridge._fileFns`) now also carries the Java sandbox — a shared
/// `resolveWithinAllowedBase` containment check that rejects paths
/// outside the job base / git root / system tmpdir with the standard
/// `{"error": …}` envelope (Java answers null/false there; the Dart
/// error-envelope convention wins for the whole family, matching
/// `listFiles` — decision recorded in the commit message per AGENTS.md
/// rule 2).
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmtools/dmtools.dart' show PropertyReader, pathIsWithin;
import 'package:dmtools/src/js/tool_bridge.dart';
import 'package:dmtools/src/mcp/default_tool_registry.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory dir;

void main() {
  // Symlink-resolved (macOS `/var` → `/private/var`) to match reported entries.
  setUp(() => dir = Directory(Directory.systemTemp
      .createTempSync('dmtools_fbridge')
      .resolveSymbolicLinksSync()));
  tearDown(() => dir.deleteSync(recursive: true));
  fileListTests();
  fileExistsTests();
  fileWriteTests();
  fileSandboxTests();
  fileSandboxAllowedTests();
  fileConfiguredAllowlistTests();
  fileConfiguredAllowlistStrictTests();
}

void fileListTests() {
  group('JS-bridge file_list (Java FileTools parity, dm.ai#635)', () {
    test('returns absolute, sorted entries as {"entries": [...]}', () {
      File('${dir.path}/b.txt').writeAsStringSync('b');
      File('${dir.path}/a.txt').writeAsStringSync('a');
      Directory('${dir.path}/sub').createSync();

      final result = jsonDecode(
        ToolBridge(registry: createDefaultToolRegistry())
            .execute('file_list', {'path': dir.path}),
      ) as Map<String, dynamic>;

      final entries = (result['entries'] as List).cast<String>();
      expect(entries, hasLength(3));
      // Pin the exact expected order — sorting a copy of the
      // implementation's own output would not catch a wrong comparator.
      expect(entries.map(p.basename), orderedEquals(['a.txt', 'b.txt', 'sub']));
      for (final entry in entries) {
        expect(p.isAbsolute(entry), isTrue, reason: entry);
        // Java parity (dm.ai#635): toAbsolutePath().normalize() per entry.
        expect(p.normalize(entry), entry, reason: entry);
      }
    });

    test(
        'entries are normalized (no . or .. segments), like Java '
        'toAbsolutePath().normalize()', () {
      File('${dir.path}/b.txt').writeAsStringSync('b');
      Directory('${dir.path}/sub').createSync();

      // The redundant "/." segment must not leak into the reported entries.
      final result = jsonDecode(
        ToolBridge(registry: createDefaultToolRegistry())
            .execute('file_list', {'path': '${dir.path}/.'}),
      ) as Map<String, dynamic>;

      final entries = (result['entries'] as List).cast<String>();
      expect(
        entries,
        orderedEquals([
          p.normalize('${dir.path}/b.txt'),
          p.normalize('${dir.path}/sub'),
        ]),
      );
    });

    test('unlistable path yields the error envelope, not a crash', () {
      final result = jsonDecode(
        ToolBridge(registry: createDefaultToolRegistry())
            .execute('file_list', {'path': '${dir.path}/missing'}),
      ) as Map<String, dynamic>;
      expect(result['error'], isA<String>());
    });
  });
}

void fileExistsTests() {
  group('JS-bridge file_exists (Java FileTools parity, dm.ai#635)', () {
    test('reports true for an existing file and false for a missing one', () {
      final file = File('${dir.path}/a.txt')..writeAsStringSync('a');
      final bridge = ToolBridge(registry: createDefaultToolRegistry());

      expect(
        jsonDecode(bridge.execute('file_exists', {'path': file.path})),
        {'exists': true},
      );
      expect(
        jsonDecode(bridge.execute('file_exists', {'path': '${dir.path}/nope'})),
        {'exists': false},
      );
    });
  });
}

void fileWriteTests() {
  group(
      'JS-bridge file_write (gh-361: parent-dir behavior of Java '
      'FileTools.writeFile)', () {
    final bridge = ToolBridge(registry: createDefaultToolRegistry());

    test('creates missing parent directories before writing (gh-361)', () {
      // Java writeFile: Files.createDirectories(parentDir) before
      // Files.writeString — a write to a nested non-existent path succeeds
      // (the token-usage reporter depends on this for its cache file).
      // Since gh-365 the parent creation happens only for paths the
      // shared sandbox let through (see fileSandboxTests).
      final nested = '${dir.path}/outputs/token_usage/cache.json';

      expect(
        jsonDecode(bridge.execute('file_write', {
          'path': nested,
          'content': '{"tokens": 42}',
        })),
        {'success': true},
      );
      expect(File(nested).readAsStringSync(), '{"tokens": 42}');
    });

    test('creates multi-level parents in one call', () {
      final nested = '${dir.path}/a/b/c/d/e.txt';

      expect(
        jsonDecode(bridge.execute('file_write', {
          'path': nested,
          'content': 'deep',
        })),
        {'success': true},
      );
      expect(File(nested).readAsStringSync(), 'deep');
    });

    test('overwrites an existing file without touching the parent', () {
      Directory('${dir.path}/sub').createSync();
      final existing = '${dir.path}/sub/a.txt';
      File(existing).writeAsStringSync('old');

      expect(
        jsonDecode(bridge.execute('file_write', {
          'path': existing,
          'content': 'new',
        })),
        {'success': true},
      );
      expect(File(existing).readAsStringSync(), 'new');
    });

    test('rejects an empty path with the error envelope', () {
      final result = jsonDecode(
        bridge.execute('file_write', {'path': '', 'content': 'x'}),
      ) as Map<String, dynamic>;
      expect(result['error'], isA<String>());
    });
  });
}

/// gh-365: every bridge `file_*` tool carries the Java `FileTools`
/// sandbox — `resolveWithinAllowedBase` shared with the async
/// [FileToolExecutor] surface — rejecting paths outside the job base /
/// git root / system tmpdir with the standard `{"error": …}` envelope.
void fileSandboxTests() {
  fileSandboxEscapeTests();
  fileSandboxEndpointTests();
  fileSandboxSymlinkParentTests();
}

/// The tool→args table for the escape tests: every bridge `file_*` tool
/// with an outside endpoint (the in-base `${dir.path}/src.txt` source is
/// pre-created by the section's setUp).
Map<String, Map<String, dynamic>> _escapeCalls(String outside) => {
      'file_read': {'path': outside},
      'file_write': {'path': outside, 'content': 'x'},
      'file_list': {'path': outside},
      'file_exists': {'path': outside},
      'file_delete': {'path': outside},
      'file_mkdir': {'path': outside},
      'file_read_lines': {'path': outside},
      'file_write_lines': {
        'path': outside,
        'lines': const ['x']
      },
      'file_append': {'path': outside, 'content': 'x'},
      'file_info': {'path': outside},
      'file_copy': {'source': '${dir.path}/src.txt', 'dest': outside},
      'file_move': {'source': '${dir.path}/src.txt', 'dest': outside},
    };

/// The whole family must reject escaping paths with the error envelope —
/// table-driven over every entry of the bridge dispatch map.
void fileSandboxEscapeTests() {
  group('JS-bridge file_* sandbox (gh-365)', () {
    late ToolBridge bridge;

    setUp(() {
      bridge = ToolBridge(
        registry: createDefaultToolRegistry(),
        workingDirectory: dir.path,
      );
      // An allowed in-base source so a rejected copy/move is attributable
      // to its outside endpoint, not the source.
      File('${dir.path}/src.txt').writeAsStringSync('payload');
    });

    test('every family tool rejects an escaping .. segment with the envelope',
        () {
      // Two levels up from the one-level-deep temp base reach the
      // filesystem root — outside the base, its git root (none), and the
      // system tmpdir.
      final escape = '${dir.path}/../../../etc/dmtools-should-not-exist';
      _escapeCalls(escape).forEach((tool, args) {
        final result =
            jsonDecode(bridge.execute(tool, args)) as Map<String, dynamic>;
        expect(result['error'], isA<String>(),
            reason: '$tool must reject $escape');
      });
      expect(File('/etc/dmtools-should-not-exist').existsSync(), isFalse,
          reason: 'the escape must not materialize on disk');
    });

    test('every family tool rejects an absolute path outside the sandbox', () {
      const outside = '/etc/hosts';
      // list/mkdir get directory-shaped targets; the rest point at a
      // file that must not be read, written, or removed.
      final calls = _escapeCalls(outside)
        ..['file_list'] = {'path': '/etc'}
        ..['file_mkdir'] = {'path': '/etc/dmtools-blocked-dir'};
      calls.forEach((tool, args) {
        final result =
            jsonDecode(bridge.execute(tool, args)) as Map<String, dynamic>;
        expect(result['error'], isA<String>(),
            reason: '$tool must reject $outside');
      });
      expect(File('${dir.path}/leak.txt').existsSync(), isFalse,
          reason: 'an outside source must not be copied into the base');
    });

    test('the error names the Java spec wording', () {
      final result = jsonDecode(
        bridge.execute('file_read', {'path': '/etc/hosts'}),
      ) as Map<String, dynamic>;

      expect(result['error'], contains('Path traversal attempt blocked'));
    });
  });
}

/// Endpoint-specific rejections: escapes must not materialize anything
/// outside the base, and rejected copy/move keep the base unchanged.
void fileSandboxEndpointTests() {
  group('JS-bridge file_* sandbox endpoints (gh-365)', () {
    late ToolBridge bridge;

    setUp(() {
      bridge = ToolBridge(
        registry: createDefaultToolRegistry(),
        workingDirectory: dir.path,
      );
      File('${dir.path}/src.txt').writeAsStringSync('payload');
    });

    test('file_mkdir creates nothing outside the base', () {
      final result = jsonDecode(
        bridge.execute('file_mkdir', {
          'path': '${dir.path}/../..//etc/dmtools-blocked-dir',
        }),
      ) as Map<String, dynamic>;

      expect(result['error'], isA<String>());
      expect(Directory('/etc/dmtools-blocked-dir').existsSync(), isFalse);
    });

    test('copy into the base from outside throws instead of leaking', () {
      final result = jsonDecode(
        bridge.execute('file_copy', {
          'source': '/etc/hosts',
          'dest': '${dir.path}/leak.txt',
        }),
      ) as Map<String, dynamic>;

      expect(result['error'], isA<String>());
      expect(File('${dir.path}/leak.txt').existsSync(), isFalse);
    });

    test('move out of the base throws and keeps the source', () {
      final result = jsonDecode(
        bridge.execute('file_move', {
          'source': '${dir.path}/src.txt',
          'dest': '/etc/dmtools-leak.txt',
        }),
      ) as Map<String, dynamic>;

      expect(result['error'], isA<String>());
      expect(File('${dir.path}/src.txt').existsSync(), isTrue);
    });
  });
}

/// gh-365 rework: a first write through an in-base symlinked parent —
/// the blocking-review escape shape (the symlink exists, only the final
/// component is missing) — must resolve through the link and answer the
/// standard envelope instead of materializing outside the base.
void fileSandboxSymlinkParentTests() {
  group('JS-bridge file_* sandbox symlinked parents (gh-365 rework)', () {
    test('a first write through an in-base symlinked parent is rejected', () {
      final bridge = ToolBridge(
        registry: createDefaultToolRegistry(),
        workingDirectory: dir.path,
      );
      Link('${dir.path}/sub').createSync('/etc');
      final target = '${dir.path}/sub/escape.txt';

      final result = jsonDecode(
        bridge.execute('file_write', {'path': target, 'content': 'x'}),
      ) as Map<String, dynamic>;

      expect(result['error'], contains('Path traversal attempt blocked'));
      expect(File('/etc/escape.txt').existsSync(), isFalse);
    });
  });
}

/// No false rejections: in-base nested paths and foreign system-temp
/// paths (the shape of every existing bridge test fixture) stay allowed.
void fileSandboxAllowedTests() {
  fileSandboxInBaseAllowedTests();
  fileSandboxTmpdirAllowedTests();
}

/// An in-base nested path round-trips through the whole family.
void fileSandboxInBaseAllowedTests() {
  group('JS-bridge file_* sandbox allows in-base paths (gh-365)', () {
    test('a nested in-base path still round-trips', () {
      final bridge = ToolBridge(
        registry: createDefaultToolRegistry(),
        workingDirectory: dir.path,
      );
      final nested = '${dir.path}/outputs/reports/report.md';

      expect(
        jsonDecode(bridge.execute('file_write', {
          'path': nested,
          'content': '# report',
        })),
        {'success': true},
      );
      expect(
        jsonDecode(bridge.execute('file_read', {'path': nested})),
        {'content': '# report'},
      );
      expect(
        jsonDecode(bridge.execute('file_exists', {'path': nested})),
        {'exists': true},
      );
      expect(
        jsonDecode(
          bridge.execute('file_append', {'path': nested, 'content': '\nend'}),
        ),
        {'success': true},
      );
      expect(
        jsonDecode(bridge.execute('file_read_lines', {'path': nested})),
        {
          'lines': ['# report', 'end']
        },
      );
      expect(
        jsonDecode(bridge.execute('file_info', {'path': nested}))['exists'],
        isTrue,
      );
    });
  });
}

/// A system-temp path outside the working directory stays allowed — the
/// tmpdir is an allowed base for every job.
void fileSandboxTmpdirAllowedTests() {
  group('JS-bridge file_* sandbox allows tmpdir paths (gh-365)', () {
    test('a system-temp path outside the working directory stays allowed', () {
      final bridge = ToolBridge(
        registry: createDefaultToolRegistry(),
        workingDirectory: dir.path,
      );
      final other = Directory.systemTemp.createTempSync('dmtools_fbridge_tm');
      try {
        final target = '${other.path}/shared.txt';

        expect(
          jsonDecode(bridge.execute('file_write', {
            'path': target,
            'content': 'tmp',
          })),
          {'success': true},
        );
        expect(
          jsonDecode(bridge.execute('file_read', {'path': target})),
          {'content': 'tmp'},
        );
      } finally {
        other.deleteSync(recursive: true);
      }
    });
  });
}

/// gh-367: the `DMTOOLS_FILE_READ_ALLOWED_PATHS` escape hatch on the
/// synchronous bridge surface — the path the SM pack's `require()` chain
/// actually takes (`file_read` of `~/.dmtools/packs/<pack>/js/*.js`).
/// Read-flavored tools (`file_read`, `file_exists`, `file_list`,
/// `file_read_lines`, `file_info`) admit a path only the configured globs
/// allow (Java `FileTools.readFile`/`resolveSandboxedPath` consult
/// `isAllowedByConfig`); write-flavored tools keep the strict guard.
class _BridgePackFixture {
  final String? home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  bool get usable {
    final h = home;
    return h != null &&
        h.isNotEmpty &&
        !pathIsWithin(h, Directory.systemTemp.path);
  }

  late ToolBridge bridge;
  late String packJs;
  late String module;

  void setUp() {
    bridge = ToolBridge(
      registry: createDefaultToolRegistry(),
      workingDirectory: dir.path,
    );
    packJs = '$home/.dmtools-gh367-test-bridge/packs/sm_github-0.1.36/js';
    Directory(packJs).createSync(recursive: true);
    module = '$packJs/configLoader.js';
    File(module).writeAsStringSync('module.exports={};');
    PropertyReader.setOverrides({
      'DMTOOLS_FILE_READ_ALLOWED_PATHS': '$home/.dmtools-gh367-test-bridge/**',
    });
  }

  void tearDown() {
    PropertyReader.clearOverrides();
    Directory('$home/.dmtools-gh367-test-bridge').deleteSync(recursive: true);
  }
}

void fileConfiguredAllowlistTests() {
  final f = _BridgePackFixture();

  group('JS-bridge file_read configured allow-list (gh-367)',
      skip: f.usable ? null : 'no HOME outside the tmpdir to test against', () {
    setUp(f.setUp);
    tearDown(f.tearDown);

    test('file_read answers the pack module content', () {
      expect(
        jsonDecode(f.bridge.execute('file_read', {'path': f.module})),
        {'content': 'module.exports={};'},
      );
    });

    test('the read-flavored family admits the pack dir', () {
      File('${f.packJs}/second.js').writeAsStringSync('// 2');

      expect(
        (jsonDecode(f.bridge.execute('file_exists', {'path': f.module}))
            as Map<String, dynamic>)['exists'],
        isTrue,
      );
      final listed =
          jsonDecode(f.bridge.execute('file_list', {'path': f.packJs}))
              as Map<String, dynamic>;
      expect((listed['entries'] as List).cast<String>(),
          containsAll([f.module, '${f.packJs}/second.js']));
      expect(
        jsonDecode(f.bridge.execute('file_read_lines', {'path': f.module})),
        {
          'lines': ['module.exports={};']
        },
      );
    });
  });
}

/// The strict half: Java's write path never consults the config, and the
/// read allowance is the config's — clearing the override re-blocks.
void fileConfiguredAllowlistStrictTests() {
  final f = _BridgePackFixture();

  group('JS-bridge file_write ignores the configured allow-list (gh-367)',
      skip: f.usable ? null : 'no HOME outside the tmpdir to test against', () {
    setUp(f.setUp);
    tearDown(f.tearDown);

    test('file_write to the same path keeps the strict envelope', () {
      final result = jsonDecode(
        f.bridge.execute('file_write', {'path': f.module, 'content': 'x'}),
      ) as Map<String, dynamic>;

      expect(result['error'], contains('Path traversal attempt blocked'));
      expect(File(f.module).readAsStringSync(), 'module.exports={};',
          reason: 'the write must not land');
    });

    test('without the override the same read stays blocked', () {
      PropertyReader.clearOverrides();

      final result =
          jsonDecode(f.bridge.execute('file_read', {'path': f.module}))
              as Map<String, dynamic>;
      expect(result['error'], contains('Path traversal attempt blocked'));
    });
  });
}
