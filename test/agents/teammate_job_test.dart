/// Tests for the Teammate job — ticket selection via `inputJql`, per-ticket
/// CliAgent delegation, the CI-run trace comment, and factory/dispatcher
/// wiring.
///
/// The tracker interactions are injected as fakes ([TeammateJob.ticketSource]
/// / [TeammateJob.commentPoster]) — no network involved.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

void main() {
  inputJqlGuardTests();
  delegationRunTests();
  delegationFailureTests();
  inputContextTests();
  tracePostingTests();
  githubTracePostingTests();
  tracePrefixTests();
  traceDisabledTests();
  resultShapeTests();
  extractKeysTests();
  commentsHydrateTests();
  jiraTicketSourceTests();
  factoryTests();
}

final hydratedTicket = {
  'key': 'PROJ-1',
  'fields': {
    'summary': 'Ship the thing',
    'description': 'Final polish and release.',
    'status': {'name': 'To Do'},
    'comment': {
      'comments': [
        {
          'author': {'name': 'alice'},
          'body': 'Please include the changelog.',
        },
      ],
    },
  },
};

Map<String, dynamic> secondTicket() => {
      'key': 'PROJ-2',
      'fields': {'summary': 'Second', 'description': 'Another one.'},
    };

// ======================================================================
// inputJql guard
// ======================================================================

void inputJqlGuardTests() {
  group('TeammateJob inputJql guard', () {
    test('no inputJql → success with empty results, source not called',
        () async {
      final tmp = await _createTempDir();
      var called = false;
      try {
        final job = TeammateJob(
          params: {
            'cliCommands': ['echo hi']
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async {
            called = true;
            return [hydratedTicket];
          },
        );
        final result = await job.run();
        expect(result['success'], isTrue);
        expect(result['results'], isEmpty);
        expect(called, isFalse);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    inputPassthroughTest();

    test('blank inputJql → success with empty results', () async {
      final tmp = await _createTempDir();
      try {
        final job = TeammateJob(
          params: {'inputJql': '   '},
          workingDirectory: tmp.path,
          ticketSource: (_) async => [hydratedTicket],
        );
        final result = await job.run();
        expect(result['success'], isTrue);
        expect(result['results'], isEmpty);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

/// Caller-prepared `input/ticket.md` (the ai-teammate convention)
/// passes through as a single synthetic ticket.
void inputPassthroughTest() {
  test('no inputJql + prepared input/ticket.md → single CliAgent pass-through',
      () async {
    final tmp = await _createTempDir();
    try {
      Directory('${tmp.path}/input').createSync(recursive: true);
      File('${tmp.path}/input/ticket.md').writeAsStringSync(
          'Fix the flaky login test\nSteps: run suite twice, watch it fail');
      final job = TeammateJob(
        params: {
          'metadata': {'contextId': 'bug_development'},
          'cliCommands': ['echo ticket-done'],
          // keep the built context around for the assertion below
          'cleanupInputFolder': false,
        },
        workingDirectory: tmp.path,
      );
      final result = await job.run();
      expect(result['success'], isTrue);
      final results = (result['results'] as List).cast<Map>();
      expect(results, hasLength(1));
      expect(results.single['ticket'], 'bug_development');
      // The canonical per-context input was built from the prepared file.
      final ctx = File('${tmp.path}/input/bug_development/ticket.md')
          .readAsStringSync();
      expect(ctx, contains('Fix the flaky login test'));
      expect(ctx, contains('Steps: run suite twice'));
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('prepared input/ticket.md is consumed — deleted after pass-through',
      () async {
    final tmp = await _createTempDir();
    try {
      Directory('${tmp.path}/input').createSync(recursive: true);
      File('${tmp.path}/input/ticket.md').writeAsStringSync(
          'Consume the bootstrap\nbody that only matters in memory');
      final job = TeammateJob(
        params: {
          'metadata': {'contextId': 'bug_development'},
          'cliCommands': ['echo ticket-done'],
        },
        workingDirectory: tmp.path,
      );
      final result = await job.run();
      expect(result['success'], isTrue);
      // The bootstrap must not survive: it duplicates the ticket body next
      // to the canonical input/<contextId>/ context and leaks an uncommitted
      // runtime file into the agent's git flow (gh-671: the branch-setup
      // stash popped it with `<<<<<<< Updated upstream` markers that the
      // agent's git add -A then committed).
      expect(File('${tmp.path}/input/ticket.md').existsSync(), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}

// ======================================================================
// Per-ticket CliAgent delegation
// ======================================================================

void delegationRunTests() {
  group('TeammateJob delegation', () {
    test('runs one CliAgent per ticket and pins contextId to the key',
        () async {
      final tmp = await _createTempDir();
      final log = '${tmp.path}/runs.log';
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'key in (PROJ-1, PROJ-2)',
            'cliCommands': ['echo cli >> "$log"'],
            'cleanupInputFolder': false,
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [hydratedTicket, secondTicket()],
        );
        final result = await job.run();
        expect(result['success'], isTrue);
        final results = result['results'] as List;
        expect(results, hasLength(2));
        expect(results[0]['ticket'], 'PROJ-1');
        expect(results[0]['success'], isTrue);
        expect(results[1]['ticket'], 'PROJ-2');
        // Each ticket got its own input folder named by key.
        expect(Directory('${tmp.path}/input/PROJ-1').existsSync(), isTrue);
        expect(Directory('${tmp.path}/input/PROJ-2').existsSync(), isTrue);
        // cliCommands ran once per ticket.
        final lines = (await File(log).readAsString()).trim().split('\n');
        expect(lines, hasLength(2));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void delegationFailureTests() {
  group('TeammateJob failure semantics', () {
    test('command failure surfaces in the response but keeps the lifecycle',
        () async {
      final tmp = await _createTempDir();
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'key in (PROJ-1)',
            'cliCommands': ['exit 3'],
            'cleanupInputFolder': false,
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [hydratedTicket],
        );
        final result = await job.run();
        // Java parity: the lifecycle completes (reset always runs); the
        // command error is visible in the response text, not as a thrown
        // agent failure.
        expect(result['success'], isTrue);
        final results = result['results'] as List;
        expect(results.single['success'], isTrue);
        expect(results.single['response'], contains('CLI Command: exit 3'));
        expect(results.single['response'], contains('Error'));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

// ======================================================================
// Input context contents
// ======================================================================

void inputContextTests() {
  group('TeammateJob input context', () {
    test('writes ticket.md, ticket.json, comments.md into input/<key>',
        () async {
      final tmp = await _createTempDir();
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'key in (PROJ-1)',
            'cliCommands': ['echo done'],
            'cleanupInputFolder': false,
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [hydratedTicket],
        );
        await job.run();
        final dir = '${tmp.path}/input/PROJ-1';
        expect(
          File('$dir/ticket.md').readAsStringSync(),
          contains('# PROJ-1: Ship the thing'),
        );
        final ticketJson =
            jsonDecode(File('$dir/ticket.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(ticketJson['key'], 'PROJ-1');
        expect(
          File('$dir/comments.md').readAsStringSync(),
          contains('Please include the changelog.'),
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

// ======================================================================
// CI-run trace comment
// ======================================================================

void tracePostingTests() {
  group('TeammateJob trace comment — posting', () {
    test('posts trace comment when ciRunUrl + alwaysPostComments', () async {
      final tmp = await _createTempDir();
      final posted = <String, String>{};
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'key in (PROJ-1)',
            'cliCommands': ['echo done'],
            'alwaysPostComments': true,
            'ciRunUrl': 'local://host/run-1',
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [hydratedTicket],
          commentPoster: (key, body) async => posted[key] = body,
        );
        await job.run();
        expect(
            posted,
            containsPair(
                'PROJ-1',
                'Processing started. '
                    'CI Run: local://host/run-1'));
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('comments enabled via non-none outputType', () async {
      final tmp = await _createTempDir();
      var posted = 0;
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'key in (PROJ-1)',
            'cliCommands': ['echo done'],
            'outputType': 'comment',
            'ciRunUrl': 'ci://run',
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [hydratedTicket],
          commentPoster: (_, __) async => posted++,
        );
        await job.run();
        expect(posted, 1);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void githubTracePostingTests() {
  group('TeammateJob trace comment — GitHub source', () {
    test('GitHub-sourced tickets get the trace comment too (gh-35)', () async {
      final tmp = await _createTempDir();
      final posted = <String, String>{};
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'repo:acme/widgets is:issue is:open label:bug',
            'cliCommands': ['echo done'],
            'alwaysPostComments': true,
            'ciRunUrl': 'ci://run',
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [
            {
              'key': 'GH-1',
              'fields': {'summary': 's', 'description': 'd'},
            },
          ],
          commentPoster: (key, body) async => posted[key] = body,
        );
        final result = await job.run();
        expect(result['success'], isTrue);
        expect(posted,
            containsPair('GH-1', 'Processing started. CI Run: ci://run'));
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('a failing GitHub trace comment does not fail the job', () async {
      final tmp = await _createTempDir();
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'repo:acme/widgets#1',
            'cliCommands': ['echo done'],
            'alwaysPostComments': true,
            'ciRunUrl': 'ci://run',
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [
            {
              'key': 'GH-1',
              'fields': {'summary': 's', 'description': 'd'},
            },
          ],
          commentPoster: (key, _) async => throw StateError('poster down'),
        );
        final result = await job.run();
        expect(result['success'], isTrue, reason: 'Java warns and continues');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void tracePrefixTests() {
  group('TeammateJob trace comment — agent name prefix', () {
    test('prefixes comment with the metadata contextId', () async {
      final tmp = await _createTempDir();
      final bodies = <String>[];
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'key in (PROJ-1)',
            'cliCommands': ['echo done'],
            'alwaysPostComments': true,
            'ciRunUrl': 'ci://run',
            'metadata': {'contextId': 'story_dev'},
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [hydratedTicket],
          commentPoster: (_, body) async => bodies.add(body),
        );
        await job.run();
        expect(bodies.single, startsWith('[story_dev] '));
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('falls back to metadata.agentId for the prefix', () async {
      final tmp = await _createTempDir();
      final bodies = <String>[];
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'key in (PROJ-1)',
            'cliCommands': ['echo done'],
            'alwaysPostComments': true,
            'ciRunUrl': 'ci://run',
            'metadata': {'agentId': 'agent-x'},
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [hydratedTicket],
          commentPoster: (_, body) async => bodies.add(body),
        );
        await job.run();
        expect(bodies.single, startsWith('[agent-x] '));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

void traceDisabledTests() {
  group('TeammateJob trace comment — disabled', () {
    test('no comment without ciRunUrl', () async {
      final tmp = await _createTempDir();
      var posted = 0;
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'key in (PROJ-1)',
            'cliCommands': ['echo done'],
            'alwaysPostComments': true,
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [hydratedTicket],
          commentPoster: (_, __) async => posted++,
        );
        await job.run();
        expect(posted, 0);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('no comment when comments disabled (outputType none)', () async {
      final tmp = await _createTempDir();
      var posted = 0;
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'key in (PROJ-1)',
            'cliCommands': ['echo done'],
            'outputType': 'none',
            'ciRunUrl': 'ci://run',
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [hydratedTicket],
          commentPoster: (_, __) async => posted++,
        );
        await job.run();
        expect(posted, 0);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

// ======================================================================
// Result shape
// ======================================================================

void resultShapeTests() {
  group('TeammateJob result shape', () {
    test('search result without key → failed item, no agent run', () async {
      final tmp = await _createTempDir();
      try {
        final job = TeammateJob(
          params: {
            'inputJql': 'summary ~ broken',
            'cliCommands': ['echo never'],
          },
          workingDirectory: tmp.path,
          ticketSource: (_) async => [
            {
              'fields': {'summary': 'no key here'}
            },
          ],
        );
        final result = await job.run();
        expect(result['success'], isFalse);
        final results = result['results'] as List;
        expect(results.single['error'], contains('ticket key'));
        expect(Directory('${tmp.path}/input').existsSync(), isFalse);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

// ======================================================================
// Jira payload parsing helpers (default ticket source)
// ======================================================================

void extractKeysTests() {
  group('Teammate extractTicketKeys', () {
    test('accepts the bare issues array', () {
      final keys = extractTicketKeys(
          '[{"key":"A-1","fields":{}},{"key":"A-2","fields":{}}]');
      expect(keys, ['A-1', 'A-2']);
    });

    test('accepts the paged {issues: [...]} map', () {
      final keys = extractTicketKeys('{"issues":[{"key":"B-7"}],"total":1}');
      expect(keys, ['B-7']);
    });

    test('returns empty for junk payloads', () {
      expect(extractTicketKeys(null), isEmpty);
      expect(extractTicketKeys(''), isEmpty);
      expect(extractTicketKeys('not json'), isEmpty);
      expect(extractTicketKeys('{"unexpected":[]}'), isEmpty);
      expect(extractTicketKeys('[{"no_key":1}]'), isEmpty);
    });
  });
}

void commentsHydrateTests() {
  group('Teammate decodeCommentsPayload', () {
    test('accepts the {comments: [...]} response', () {
      final comments =
          decodeCommentsPayload('{"comments":[{"body":"hi"}],"total":1}');
      expect(comments, hasLength(1));
      expect((comments!.single as Map)['body'], 'hi');
    });

    test('accepts a bare array and rejects junk', () {
      expect(decodeCommentsPayload('[{"body":"a"}]'), hasLength(1));
      expect(decodeCommentsPayload(null), isNull);
      expect(decodeCommentsPayload('{}'), isNull);
      expect(decodeCommentsPayload('oops'), isNull);
    });
  });

  group('Teammate hydrateTicket', () {
    test('merges comments into fields and decodes the ticket', () {
      final ticket = hydrateTicket(
        rawTicket: '{"key":"C-1","fields":{"summary":"s"}}',
        rawComments: '{"comments":[{"body":"b"}]}',
        key: 'C-1',
      );
      expect(ticket['key'], 'C-1');
      expect(ticket['fields']['summary'], 's');
      final commentField = ticket['fields']['comment'] as Map;
      expect((commentField['comments'] as List).single, isA<Map>());
    });

    test('falls back to the key when the ticket is undecodable', () {
      final ticket = hydrateTicket(rawTicket: 'garbage', key: 'C-2');
      expect(ticket, {'key': 'C-2'});
    });

    test('keeps the ticket untouched when comments are empty', () {
      final ticket = hydrateTicket(
        rawTicket: '{"key":"C-3","fields":{"summary":"s"}}',
        rawComments: null,
        key: 'C-3',
      );
      expect((ticket['fields'] as Map).containsKey('comment'), isFalse);
    });
  });
}

void jiraTicketSourceTests() {
  group('Teammate jiraTicketSource', () {
    test(
        'requests *navigable and attachment fields on jira_get_ticket (gh-461)',
        () async {
      final calls = <({String tool, Map<String, dynamic> args})>[];
      final tickets = await jiraTicketSource(
        'key in (MAPC-8190)',
        execute: (tool, args) {
          calls.add((tool: tool, args: args));
          if (tool == 'jira_search_by_jql') {
            return '[{"key":"MAPC-8190"}]';
          }
          if (tool == 'jira_get_ticket') {
            return '{"key":"MAPC-8190","fields":{"summary":"s","attachment":[{"filename":"shot.png","content":"https://x.atlassian.net/rest/api/2/attachment/content/1"}]}}';
          }
          return '{"comments":[]}';
        },
      );
      final getCall = calls.firstWhere((c) => c.tool == 'jira_get_ticket');
      expect(getCall.args['key'], 'MAPC-8190');
      expect(getCall.args['fields'], ['*navigable', 'attachment']);
      expect(
        (tickets.single['fields'] as Map)['attachment'],
        isA<List>(),
      );
    });
  });
}

// ======================================================================
// Factory dispatch
// ======================================================================

void factoryTests() {
  group('AgentFactory teammate dispatch', () {
    test("create('teammate') returns a TeammateJob", () {
      expect(
        AgentFactory.create('teammate', {'inputJql': 'key = P-1'}),
        isA<TeammateJob>(),
      );
    });

    test("create('Teammate') is case-insensitive", () {
      expect(
        AgentFactory.create('Teammate', const {}),
        isA<TeammateJob>(),
      );
    });
  });
}

Future<Directory> _createTempDir() async =>
    Directory.systemTemp.createTemp('teammate_job_test');
