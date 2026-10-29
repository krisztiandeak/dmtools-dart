/// Unit tests for [autoDetectAndDecode] (Java `EncodingDetector` port).
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

void main() {
  _testBase64Decode();
  _testUrlDecode();
  _testFallbackAndErrors();
  _testLeadingShellFlags();
  _testLeadingShellFlagsWithEncodedConfig();
}

void _testBase64Decode() {
  group('base64 decoding', () {
    test('decodes valid base64 text', () {
      final encoded = base64.encode(utf8.encode('hello world'));
      expect(autoDetectAndDecode(encoded), 'hello world');
    });

    test('decodes base64 with full padding', () {
      final encoded = base64.encode(utf8.encode('a'));
      expect(autoDetectAndDecode(encoded), 'a');
    });

    test('decodes base64 JSON config', () {
      const json = '{"key":"value"}';
      final encoded = base64.encode(utf8.encode(json));
      expect(autoDetectAndDecode(encoded), json);
    });

    test('rejects a length not divisible by 4', () {
      // 'abc' has length 3 — fails the base64 length check, then URL-decodes.
      expect(autoDetectAndDecode('abc'), 'abc');
    });

    test('rejects characters outside the base64 alphabet', () {
      // Length 4 but contains '%', failing both the base64 regex and the
      // URL-decode fallback.
      expect(() => autoDetectAndDecode('%%%%'), throwsArgumentError);
    });

    test('rejects base64 that decodes to invalid UTF-8', () {
      // '////' is alphabet-valid base64 decoding to 0xFFFFFF, which is not
      // UTF-8; the URL-decode fallback then returns it unchanged.
      expect(autoDetectAndDecode('////'), '////');
    });

    test('rejects an empty candidate', () {
      expect(autoDetectAndDecode(''), '');
    });
  });
}

void _testUrlDecode() {
  group('URL decoding', () {
    test('decodes percent-encoded text', () {
      expect(autoDetectAndDecode('hello%20world'), 'hello world');
    });

    test('decodes URL-encoded JSON', () {
      const encoded = '%7B%22key%22%3A%22value%22%7D';
      expect(autoDetectAndDecode(encoded), '{"key":"value"}');
    });

    test('decodes form-urlencoded JSON with + spaces', () {
      const encoded = '%7B%0A++%22params%22%3A+%7B%7D%7D';
      expect(autoDetectAndDecode(encoded), '{\n  "params": {}}');
    });

    test('preserves literal plus signs encoded as %2B alongside + spaces', () {
      const encoded = '%7B%22expr%22%3A+%22a%2Bb%22%7D';
      expect(autoDetectAndDecode(encoded), '{"expr": "a+b"}');
    });

    test('still decodes valid base64 containing + before URL decoding', () {
      const text = '>>>???'; // base64 is 'Pj4+Pz8/' (contains '+')
      final encoded = base64.encode(utf8.encode(text));
      expect(encoded, contains('+'));
      expect(autoDetectAndDecode(encoded), text);
    });

    test('returns plain ASCII unchanged', () {
      expect(autoDetectAndDecode('plain'), 'plain');
    });
  });
}

void _testFallbackAndErrors() {
  group('fallback and errors', () {
    test('throws ArgumentError when both decoders fail', () {
      expect(() => autoDetectAndDecode('%%%'), throwsArgumentError);
    });
  });
}

void _testLeadingShellFlags() {
  group('CliDispatcher leading global verbosity flags (gh-455)', () {
    late Directory tmp;
    late List<String> lines;
    late CliDispatcher dispatcher;

    setUp(() {
      PropertyReader.testIsolation = true;
      tmp = Directory.systemTemp.createTempSync('dmtools_cli_flags_');
      PropertyReader.setOverrides({});
      lines = [];
      dispatcher = CliDispatcher(
        writer: lines.add,
        propertyReader: PropertyReader(basePath: tmp.path),
        isTty: () => false,
      );
    });

    tearDown(() {
      PropertyReader.clearOverrides();
      PropertyReader.testIsolation = false;
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('--debug before run and --verbose/--quiet before list/doctor/tool',
        () async {
      final jsFile = File('${tmp.path}/debug_fn.js')
        ..writeAsStringSync('function action(params) { return 42; }');
      expect(await dispatcher.dispatch(['--debug', 'run', jsFile.path]), 0);
      expect(lines.last, '42');
      expect(await dispatcher.dispatch(['--verbose', 'list']), 0);
      expect(await dispatcher.dispatch(['--quiet', 'doctor']), 0);
      final testFile = File('${tmp.path}/leading_flags.txt')
        ..writeAsStringSync('flag content');
      expect(
        await dispatcher.dispatch([
          '--debug',
          '--verbose',
          '--quiet',
          'file_read',
          '--path',
          testFile.path,
        ]),
        0,
      );
      expect((jsonDecode(lines.last) as Map<String, dynamic>)['content'],
          'flag content');
    });
  });
}

void _testLeadingShellFlagsWithEncodedConfig() {
  group('CliDispatcher leading --debug with form-urlencoded config (gh-455)',
      () {
    test('--debug before run with form-urlencoded + encoded config', () async {
      PropertyReader.testIsolation = true;
      final tmp = Directory.systemTemp.createTempSync('dmtools_cli_enc_');
      final lines = <String>[];
      final dispatcher = CliDispatcher(
        writer: lines.add,
        propertyReader: PropertyReader(basePath: tmp.path),
        isTty: () => false,
      );
      try {
        final jsFile = File('${tmp.path}/debug_encoded.js')
          ..writeAsStringSync(
            'function action(params) { return params.jobParams.greeting; }',
          );
        const encoded =
            '%7B%0A++%22params%22%3A+%7B%22jobParams%22%3A+%7B%22greeting%22%3A+%22hi+there%22%7D%7D%7D';
        expect(
          await dispatcher.dispatch(
            ['--debug', 'run', jsFile.path, '--debug', encoded],
          ),
          0,
        );
        expect(jsonDecode(lines.last), 'hi there');
      } finally {
        PropertyReader.clearOverrides();
        PropertyReader.testIsolation = false;
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    });
  });
}
