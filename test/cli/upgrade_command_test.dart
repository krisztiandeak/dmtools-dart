/// Unit tests for [UpgradeCommand] (gh-395, dm.ai #701 parity).
///
/// Written against the main-line implementation (gh-384/#414): the runtime
/// reachability (`mcp upgrade`) is gh-395's add-on — covered by the
/// dispatcher routing test below.
library;

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

/// Shared fakes: captured output + download/install call log.
class _Harness {
  final out = <String>[];
  final downloads = <String>[];
  final installs = <Map<String, String>>[];

  UpgradeCommand cmd({
    bool dryRun = false,
    Future<String?> Function(String url)? fetch,
    int installerCode = 0,
  }) =>
      UpgradeCommand(
        writer: out.add,
        environment: {
          if (dryRun) 'DMTOOLS_UPGRADE_DRY_RUN': 'true',
        },
        fetchScript: (url) async {
          downloads.add(url);
          return fetch == null ? '/tmp/install.sh' : fetch(url);
        },
        runScript: (path, env) async {
          installs.add(env);
          return installerCode;
        },
      );
}

void main() {
  group('version validation', _versionValidation);
  group('install flow', _installFlow);
  group('dispatcher', _dispatcherRouting);
}

void _versionValidation() {
  late _Harness h;
  setUp(() => h = _Harness());

  test('rejects invalid version before any download or install', () async {
    expect(await h.cmd().run(['1.2']), 2);
    expect(await h.cmd().run(['1.2.3;echo']), 2);
    expect(h.downloads, isEmpty);
    expect(h.installs, isEmpty);
    expect(h.out.where((l) => l.contains('Invalid version')).length, 2);
  });

  test('accepts 1.2.3 and v1.2.3 and pins the tag', () async {
    expect(await h.cmd().run(['1.2.3']), 0);
    expect(await h.cmd().run(['v1.2.3']), 0);
    expect(h.installs, [
      containsPair('DMTOOLS_VERSION', '1.2.3'),
      containsPair('DMTOOLS_VERSION', 'v1.2.3'),
    ]);
    expect(
      h.downloads.first,
      'https://github.com/epam/dmtools-dart/releases/download/v1.2.3/install.sh',
    );
  });

  test('no version uses latest release installer', () async {
    expect(await h.cmd().run([]), 0);
    expect(
      h.downloads.single,
      'https://github.com/epam/dmtools-dart/releases/latest/download/install.sh',
    );
    expect(h.installs.single, isNot(contains('DMTOOLS_VERSION')));
  });
}

void _installFlow() {
  late _Harness h;
  setUp(() => h = _Harness());

  test('dry run changes nothing', () async {
    expect(await h.cmd(dryRun: true).run(['1.2.3']), 0);
    expect(h.downloads, isEmpty);
    expect(h.installs, isEmpty);
    expect(h.out, anyElement(contains('Dry run')));
  });

  test('failed download runs nothing and returns 1', () async {
    final code = await h.cmd(fetch: (_) async => null).run(['1.2.3']);
    expect(code, 1);
    expect(h.installs, isEmpty);
    expect(h.out, anyElement(contains('could not download')));
  });

  test('failing installer returns its exit code', () async {
    expect(await h.cmd(installerCode: 7).run(['1.2.3']), 7);
    expect(h.out, anyElement(contains('code 7')));
  });
}

void _dispatcherRouting() {
  test(
    'dispatcher routes upgrade, update and mcp upgrade to the same command',
    () async {
      final lines = <String>[];
      final dispatcher = CliDispatcher(
        writer: lines.add,
        errorWriter: lines.add,
        isTty: () => false,
      );
      // Invalid version keeps the test offline: rejected before any download.
      expect(await dispatcher.dispatch(['upgrade', 'bad']), 2);
      expect(await dispatcher.dispatch(['update', 'bad']), 2);
      expect(await dispatcher.dispatch(['mcp', 'upgrade', 'bad']), 2);
      expect(await dispatcher.dispatch(['mcp', 'update', 'bad']), 2);
      expect(lines.where((l) => l.contains('Invalid version')).length, 4);
    },
  );

  test('old launcher sends mcp upgrade and still reaches the command',
      () async {
    final lines = <String>[];
    final dispatcher = CliDispatcher(
      writer: lines.add,
      errorWriter: lines.add,
      isTty: () => false,
    );
    expect(await dispatcher.dispatch(['mcp', 'upgrade', 'not-a-version']), 2);
    expect(lines.any((l) => l.contains('Invalid version')), isTrue);
  });
}
