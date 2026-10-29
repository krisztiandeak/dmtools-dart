import 'dart:io';

import 'package:dmtools/src/pack/pack_provenance.dart';
import 'package:test/test.dart';

void main() {
  group('PackProvenance', () {
    test('round-trips through the pack directory file', () {
      final dir = Directory.systemTemp.createTempSync('prov_');
      addTearDown(() => dir.deleteSync(recursive: true));
      const record = PackProvenance(
          name: 'sm_github',
          version: '0.1.36',
          sha256: 'abc',
          sourceUrl: 'https://x/sm_github-0.1.36.zip');
      record.write(dir);
      final read = PackProvenance.read(dir);
      expect(read, isNotNull);
      expect(record.matches(read), isTrue);
      expect(record.describe(), contains('sha256=abc'));
    });

    test('same version, different sha or source is not a match', () {
      const a =
          PackProvenance(name: 'n', version: '1', sha256: 'a', sourceUrl: 'u1');
      const bSha =
          PackProvenance(name: 'n', version: '1', sha256: 'b', sourceUrl: 'u1');
      const bUrl =
          PackProvenance(name: 'n', version: '1', sha256: 'a', sourceUrl: 'u2');
      expect(a.matches(bSha), isFalse);
      expect(a.matches(bUrl), isFalse);
      expect(a.matches(null), isFalse);
    });

    test('missing or malformed record reads as null', () {
      final dir = Directory.systemTemp.createTempSync('prov_');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(PackProvenance.read(dir), isNull);
      File('${dir.path}/$packProvenanceFileName').writeAsStringSync('{"x":1}');
      expect(PackProvenance.read(dir), isNull);
      expect(PackProvenance.fromJson('nope'), isNull);
    });
    test('normalizePackReferencePath respects root-level .js when present', () {
      final dir = Directory.systemTemp.createTempSync('prov_norm_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/restoreDescription.js').writeAsStringSync('// root');
      expect(
        normalizePackReferencePath(
          'agents/restoreDescription.js',
          rootPath: dir.path,
        ),
        'restoreDescription.js',
      );
      expect(
        normalizePackReferencePath(
          'assignForSolutionArchitecture.js',
          rootPath: dir.path,
        ),
        'js/assignForSolutionArchitecture.js',
      );
    });
  });
}
