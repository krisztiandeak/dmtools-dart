/// Tests for [InstructionProcessor] — file path embedding, URL and Jira key
/// annotation, and graceful handling of missing references.
library;

import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

void main() {
  filePathEmbeddingTests();
  filePathEdgeCaseTests();
  jiraKeyAnnotationTests();
  urlAnnotationTests();
  multipleReferencesTests();
  noReferencesTests();
  nonExistentFileTests();
}

// ======================================================================
// File path detection and embedding
// ======================================================================

void filePathEmbeddingTests() {
  group('InstructionProcessor file paths', () {
    test('embeds content from a relative file path', () {
      final tmp = Directory.systemTemp.createTempSync('ip_test_');
      try {
        File('${tmp.path}/notes.md').writeAsStringSync('# My Notes\nHello');
        final processor = InstructionProcessor(workingDirectory: tmp.path);
        final result = processor.process('Review ./notes.md please');
        expect(result, contains('## notes.md\n# My Notes\nHello'));
        expect(result, isNot(contains('<file path=')));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('embeds content from an absolute file path', () {
      final tmp = Directory.systemTemp.createTempSync('ip_test_');
      try {
        final file = File('${tmp.path}/config.json')
          ..writeAsStringSync('{"key": "value"}');
        final processor = InstructionProcessor();
        final result = processor.process('See ${file.path}');
        expect(result, contains('"key": "value"'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('embeds content from a parent-directory path', () {
      final tmp = Directory.systemTemp.createTempSync('ip_test_');
      try {
        Directory('${tmp.path}/sub').createSync();
        File('${tmp.path}/data.yaml').writeAsStringSync('name: test');
        final processor = InstructionProcessor(
          workingDirectory: '${tmp.path}/sub',
        );
        final result = processor.process('Check ../data.yaml');
        expect(result, contains('name: test'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ======================================================================
// File path — edge cases (extensions, repeated paths)
// ======================================================================

void filePathEdgeCaseTests() {
  group('InstructionProcessor file paths (edge cases)', () {
    test('supports txt, yaml, and yml extensions', () {
      final tmp = Directory.systemTemp.createTempSync('ip_test_');
      try {
        File('${tmp.path}/a.txt').writeAsStringSync('text-content');
        File('${tmp.path}/b.yaml').writeAsStringSync('yaml: content');
        File('${tmp.path}/c.yml').writeAsStringSync('yml: content');
        final processor = InstructionProcessor(workingDirectory: tmp.path);
        final result = processor.process('./a.txt ./b.yaml ./c.yml');
        expect(result, contains('text-content'));
        expect(result, contains('yaml: content'));
        expect(result, contains('yml: content'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('embeds each occurrence when a path repeats', () {
      final tmp = Directory.systemTemp.createTempSync('ip_test_');
      try {
        File('${tmp.path}/ref.md').writeAsStringSync('body');
        final processor = InstructionProcessor(workingDirectory: tmp.path);
        final result = processor.process('./ref.md then ./ref.md');
        expect(result, contains('## ref.md\nbody then ## ref.md'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ======================================================================
// Jira key detection and annotation
// ======================================================================

void jiraKeyAnnotationTests() {
  group('InstructionProcessor Jira keys', () {
    test('annotates a Jira ticket key', () {
      final processor = InstructionProcessor();
      final result = processor.process('Fix the bug in PROJ-123');
      expect(result, contains('PROJ-123 [jira-ticket]'));
    });

    test('annotates multiple Jira keys', () {
      final processor = InstructionProcessor();
      final result = processor.process('See PROJ-123 and ABC-456');
      expect(result, contains('PROJ-123 [jira-ticket]'));
      expect(result, contains('ABC-456 [jira-ticket]'));
    });

    test('does not annotate lowercase or short patterns', () {
      final processor = InstructionProcessor();
      const prompt = 'Check proj-123 and A-1 identifiers';
      expect(processor.process(prompt), prompt);
    });
  });
}

// ======================================================================
// URL detection and annotation
// ======================================================================

void urlAnnotationTests() {
  group('InstructionProcessor URLs', () {
    test('annotates a GitHub PR URL with structured metadata', () {
      final processor = InstructionProcessor();
      final result = processor.process(
        'Review https://github.com/owner/repo/pull/42',
      );
      expect(result, contains('[github-pr:owner/repo#42]'));
    });

    test('leaves non-GitHub URLs unchanged', () {
      final processor = InstructionProcessor();
      const prompt = 'See https://example.com/docs';
      expect(processor.process(prompt), prompt);
    });

    test('leaves GitHub non-PR URLs unchanged', () {
      final processor = InstructionProcessor();
      const prompt = 'See https://github.com/owner/repo/blob/main/lib.dart';
      expect(processor.process(prompt), prompt);
    });
  });
}

// ======================================================================
// Multiple references in one prompt
// ======================================================================

void multipleReferencesTests() {
  group('InstructionProcessor mixed references', () {
    test('processes file, Jira, and GitHub PR together', () {
      final tmp = Directory.systemTemp.createTempSync('ip_test_');
      try {
        File('${tmp.path}/spec.md').writeAsStringSync('# Spec');
        final processor = InstructionProcessor(workingDirectory: tmp.path);
        final result = processor.process(
          'Review ./spec.md for PROJ-123 '
          'and https://github.com/o/r/pull/7',
        );
        expect(result, contains('# Spec'));
        expect(result, contains('PROJ-123 [jira-ticket]'));
        expect(result, contains('[github-pr:o/r#7]'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('processes prompts from cliPrompts entries as well', () {
      final tmp = Directory.systemTemp.createTempSync('ip_test_');
      try {
        File('${tmp.path}/guide.md').writeAsStringSync('guide body');
        final builder = const CliCommandBuilder();
        final commands = builder.buildCommands(
          ['echo'],
          null,
          ['Check ./guide.md', 'Ticket: DM-9'],
          null,
          workingDirectory: tmp.path,
        );
        final promptPath = _extractPromptPath(commands.first);
        final promptContent = File(promptPath).readAsStringSync();
        expect(promptContent, contains('guide body'));
        expect(promptContent, contains('DM-9 [jira-ticket]'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ======================================================================
// No references — prompt unchanged
// ======================================================================

void noReferencesTests() {
  group('InstructionProcessor no references', () {
    test('returns plain prompt unchanged', () {
      final processor = InstructionProcessor();
      const prompt = 'Just a plain prompt with no references at all.';
      expect(processor.process(prompt), prompt);
    });

    test('handles empty string', () {
      final processor = InstructionProcessor();
      expect(processor.process(''), '');
    });

    test('ignores paths without known extensions', () {
      final processor = InstructionProcessor();
      const prompt = 'See ./README for details';
      expect(processor.process(prompt), prompt);
    });
  });
}

// ======================================================================
// Non-existent file — graceful handling
// ======================================================================

void nonExistentFileTests() {
  group('InstructionProcessor graceful handling', () {
    test('leaves non-existent file path unchanged', () {
      final processor = InstructionProcessor(
        workingDirectory: '/nonexistent/dir',
      );
      const prompt = 'Read ./missing.md for details';
      expect(processor.process(prompt), prompt);
    });

    test('leaves unreadable file path unchanged', () {
      final tmp = Directory.systemTemp.createTempSync('ip_test_');
      try {
        final file = File('${tmp.path}/locked.txt')
          ..writeAsStringSync('secret');
        file.deleteSync();
        final processor = InstructionProcessor(workingDirectory: tmp.path);
        const prompt = 'Read ./locked.txt';
        expect(processor.process(prompt), prompt);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ======================================================================
// Helpers
// ======================================================================

/// Extracts the quoted prompt-file path from a built CLI command.
String _extractPromptPath(String command) {
  final match = RegExp(r'"(.+)"').firstMatch(command);
  return match!.group(1)!;
}
