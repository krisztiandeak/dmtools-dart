/// Tests for TicketInputContextBuilder.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

void main() {
  emptyContextTests();
  fullTicketTests();
  subtaskTests();
  commentsTests();
  missingFieldsTests();
  subtaskEdgeCaseTests();
  contextPathTests();
  inputFolderNameTests();
  requestMdTests();
}

// ======================================================================
// Empty context — no ticket data
// ======================================================================

void emptyContextTests() {
  group('TicketInputContextBuilder — empty context', () {
    test('creates an empty folder when ticketData is null', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        final path = builder.build('PROJ-1');
        expect(Directory(path).existsSync(), isTrue);
        expect(Directory(path).listSync(), isEmpty);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('creates nested folders when contextId has slashes', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        final path = builder.build('batch/run-42');
        expect(Directory(path).existsSync(), isTrue);
        expect(path, '${tmp.path}/input/batch/run-42');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ======================================================================
// Full ticket data
// ======================================================================

void fullTicketTests() {
  group('TicketInputContextBuilder — full ticket', () {
    test('writes ticket.md with key, summary, status, priority, description',
        () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        builder.build('PROJ-1', ticketData: _fullTicket());
        final md =
            File('${tmp.path}/input/PROJ-1/ticket.md').readAsStringSync();
        expect(md, contains('# PROJ-100: Implement login'));
        expect(md, contains('**Status:** In Progress'));
        expect(md, contains('**Priority:** High'));
        expect(md, contains('## Description'));
        expect(md, contains('Users need a login page'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('writes ticket.json with the raw ticket data', () {
      final tmp = _createTempDir();
      try {
        final ticket = _fullTicket();
        final builder = TicketInputContextBuilder(tmp.path);
        builder.build('PROJ-1', ticketData: ticket);
        final json =
            File('${tmp.path}/input/PROJ-1/ticket.json').readAsStringSync();
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['key'], 'PROJ-100');
        expect(decoded['fields']['summary'], 'Implement login');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('returns the context folder path', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        final path = builder.build('CTX-9', ticketData: _fullTicket());
        expect(path, '${tmp.path}/input/CTX-9');
        expect(Directory(path).existsSync(), isTrue);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ======================================================================
// Subtasks
// ======================================================================

void subtaskTests() {
  group('TicketInputContextBuilder — subtasks', () {
    test('writes a markdown file per subtask', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        builder.build('PROJ-1', ticketData: _ticketWithSubtasks());
        final subtaskDir = Directory('${tmp.path}/input/PROJ-1/subtasks');
        expect(subtaskDir.existsSync(), isTrue);
        final files = subtaskDir
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .toList();
        expect(files, containsAll(['PROJ-101.md', 'PROJ-102.md']));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('subtask markdown includes key, summary, and description', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        builder.build('PROJ-1', ticketData: _ticketWithSubtasks());
        final md = File('${tmp.path}/input/PROJ-1/subtasks/PROJ-101.md')
            .readAsStringSync();
        expect(md, contains('# PROJ-101: Build form'));
        expect(md, contains('## Description'));
        expect(md, contains('Create the login form UI'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('creates no subtasks folder when there are none', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        builder.build('PROJ-1', ticketData: _fullTicket());
        expect(
          Directory('${tmp.path}/input/PROJ-1/subtasks').existsSync(),
          isFalse,
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ======================================================================
// Comments
// ======================================================================

void commentsTests() {
  group('TicketInputContextBuilder — comments', () {
    test('writes comments.md with author and body', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        builder.build('PROJ-1', ticketData: _ticketWithComments());
        final md =
            File('${tmp.path}/input/PROJ-1/comments.md').readAsStringSync();
        expect(md, contains('## Comments'));
        expect(md, contains('**Alice** (2024-01-15):'));
        expect(md, contains('This looks good'));
        expect(md, contains('**Bob** (2024-01-16):'));
        expect(md, contains('Needs tests'));
        // Comments are separated by horizontal rules.
        expect('---'.allMatches(md).length, greaterThanOrEqualTo(2));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('does not create comments.md when there are none', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        builder.build('PROJ-1', ticketData: _fullTicket());
        expect(
          File('${tmp.path}/input/PROJ-1/comments.md').existsSync(),
          isFalse,
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ======================================================================
// Missing fields — graceful handling
// ======================================================================

void missingFieldsTests() {
  group('TicketInputContextBuilder — missing fields', () {
    test('handles ticket with only a key', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        builder.build('PROJ-1', ticketData: {'key': 'LONE-1'});
        final md =
            File('${tmp.path}/input/PROJ-1/ticket.md').readAsStringSync();
        expect(md, contains('# LONE-1'));
        expect(md, contains('(no description)'));
        expect(md, isNot(contains('**Status:**')));
        expect(md, isNot(contains('**Priority:**')));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('handles empty fields map', () {
      final tmp = _createTempDir();
      try {
        TicketInputContextBuilder(tmp.path).build(
          'PROJ-1',
          ticketData: <String, dynamic>{},
        );
        expect(
          File('${tmp.path}/input/PROJ-1/ticket.md').existsSync(),
          isTrue,
        );
        expect(
          File('${tmp.path}/input/PROJ-1/ticket.json').existsSync(),
          isTrue,
        );
        expect(
          File('${tmp.path}/input/PROJ-1/ticket.md').readAsStringSync(),
          contains('# Ticket'),
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

void subtaskEdgeCaseTests() {
  group('TicketInputContextBuilder — subtask edge cases', () {
    test('handles subtasks without fields', () {
      final tmp = _createTempDir();
      try {
        TicketInputContextBuilder(tmp.path).build('PROJ-1', ticketData: {
          'key': 'P-1',
          'fields': {
            'subtasks': [
              {'key': 'S-1'},
            ],
          },
        });
        final md =
            File('${tmp.path}/input/PROJ-1/subtasks/S-1.md').readAsStringSync();
        expect(md, contains('# S-1'));
        expect(md, contains('(no description)'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('handles subtask entries that are not maps', () {
      final tmp = _createTempDir();
      try {
        TicketInputContextBuilder(tmp.path).build('PROJ-1', ticketData: {
          'key': 'P-1',
          'fields': {
            'subtasks': ['not-a-map', 42],
          },
        });
        expect(
          Directory('${tmp.path}/input/PROJ-1/subtasks').existsSync(),
          isFalse,
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ======================================================================
// Context path resolution
// ======================================================================

void contextPathTests() {
  group('TicketInputContextBuilder — path resolution', () {
    test('resolves input folder under the working directory', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        final path = builder.build('PATH-1', ticketData: _fullTicket());
        expect(path, startsWith(tmp.path));
        expect(path, endsWith('input/PATH-1'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('overwrites existing ticket.md on rebuild', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        builder.build('PROJ-1', ticketData: _fullTicket());
        builder.build('PROJ-1', ticketData: {'key': 'CHANGED-1'});
        final md =
            File('${tmp.path}/input/PROJ-1/ticket.md').readAsStringSync();
        expect(md, contains('# CHANGED-1'));
        expect(md, isNot(contains('PROJ-100')));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('maps GitHub composite key owner/repo#N to input/gh-N', () {
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        final path =
            builder.build('acme/widgets#42', ticketData: _fullTicket());
        expect(path, '${tmp.path}/input/gh-42');
        expect(File('$path/ticket.md').existsSync(), isTrue);
        expect(File('$path/ticket.json').existsSync(), isTrue);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

void inputFolderNameTests() {
  group('TicketInputContextBuilder.toInputFolderName', () {
    test('maps composite and bare GitHub keys and preserves others', () {
      expect(
        TicketInputContextBuilder.toInputFolderName('acme/widgets#42'),
        'gh-42',
      );
      expect(
        TicketInputContextBuilder.toInputFolderName('#7'),
        'gh-7',
      );
      expect(
        TicketInputContextBuilder.toInputFolderName('PROJ-123'),
        'PROJ-123',
      );
      expect(
        TicketInputContextBuilder.toInputFolderName('batch/run-42'),
        'batch/run-42',
      );
    });
  });
}

void requestMdTests() {
  group('TicketInputContextBuilder — request.md and ADO markdown', () {
    test('writes request.md matching ticket.md and parses CliAgentParams flags',
        () {
      final p = CliAgentParams.fromJson({
        'includeAttachments': false,
        'skipAllAttachments': true,
        'skipVideoAttachments': true,
      });
      expect(p.includeAttachments, isFalse);
      expect(p.skipAllAttachments, isTrue);
      expect(p.skipVideoAttachments, isTrue);
      expect(
        CliAgentParams.fromJson({
          'input': {'skipAllAttachments': 'true'}
        }).skipAllAttachments,
        isTrue,
      );
      final tmp = _createTempDir();
      try {
        final builder = TicketInputContextBuilder(tmp.path);
        builder.build('PROJ-1', ticketData: _fullTicket());
        final ticketMd =
            File('${tmp.path}/input/PROJ-1/ticket.md').readAsStringSync();
        final requestMd =
            File('${tmp.path}/input/PROJ-1/request.md').readAsStringSync();
        expect(requestMd, equals(ticketMd));
        expect(requestMd, contains('# PROJ-100: Implement login'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('formats ADO System.* fields into ticket.md and request.md', () {
      final tmp = _createTempDir();
      try {
        TicketInputContextBuilder(tmp.path).build('1234', ticketData: {
          'id': 1234,
          'fields': {
            'System.Title': 'Fix crash on launch',
            'System.State': 'Active',
            'Microsoft.VSTS.Common.Priority': 1,
            'Microsoft.VSTS.TCM.ReproSteps': 'Open app and tap login',
          },
        });
        final req =
            File('${tmp.path}/input/1234/request.md').readAsStringSync();
        expect(req, contains('# 1234: Fix crash on launch'));
        expect(req, contains('**Status:** Active'));
        expect(req, contains('**Priority:** 1'));
        expect(req, contains('Open app and tap login'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

Map<String, dynamic> _fullTicket() => {
      'key': 'PROJ-100',
      'fields': {
        'summary': 'Implement login',
        'description': 'Users need a login page with OAuth2.',
        'status': {'name': 'In Progress'},
        'priority': {'name': 'High'},
      },
    };

Map<String, dynamic> _ticketWithSubtasks() => {
      'key': 'PROJ-100',
      'fields': {
        'summary': 'Implement login',
        'description': 'Users need a login page.',
        'subtasks': [
          {
            'key': 'PROJ-101',
            'fields': {
              'summary': 'Build form',
              'description': 'Create the login form UI',
              'status': {'name': 'To Do'},
            },
          },
          {
            'key': 'PROJ-102',
            'fields': {
              'summary': 'Add OAuth2',
              'description': 'Wire up the OAuth2 flow',
            },
          },
        ],
      },
    };

Map<String, dynamic> _ticketWithComments() => {
      'key': 'PROJ-100',
      'fields': {
        'summary': 'Implement login',
        'description': 'Login page.',
        'comment': {
          'comments': [
            {
              'body': 'This looks good',
              'author': {'name': 'Alice'},
              'created': '2024-01-15',
            },
            {
              'body': 'Needs tests',
              'author': {'name': 'Bob'},
              'created': '2024-01-16',
            },
          ],
        },
      },
    };

/// Creates a unique temporary directory.
Directory _createTempDir() {
  return Directory.systemTemp.createTempSync('ticket_ctx_test_');
}
