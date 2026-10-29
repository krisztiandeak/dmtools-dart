// Fixture-server tests for the Java #524/#495 GitHub surface:
// `github_get_issue` and the native PR review tools (submit / list /
// dismiss). Split from github_sync_tools_test.dart to stay under the
// loc gate; shares its fixture subprocess conventions.
import 'dart:convert';

import 'package:dmtools/src/config/property_reader.dart';
import 'package:dmtools/src/js/sync_tools/github_sync_tools.dart';
import 'package:test/test.dart';

import '../echo_server_helper.dart';
import 'github_fixture_helper.dart';

late GithubFixtureServer fx;
late GitHubSyncTools tools;

void main() {
  setUpAll(() => PropertyReader.testIsolation = true);
  tearDownAll(() {
    PropertyReader.testIsolation = false;
    PropertyReader.testEnvironment.clear();
  });
  if (hasPython3()) {
    _issueToolTest();
    _issueMutationTests();
    _createIssueTests();
    _reviewToolTests();
  }
}

/// Binds the shared fixture server and config overrides.
Future<void> _startFixture() async {
  fx = GithubFixtureServer();
  await fx.start();
  PropertyReader.setOverrides({
    'SOURCE_GITHUB_TOKEN': 'ghp_testtoken',
    'SOURCE_GITHUB_BASE_PATH': 'http://127.0.0.1:${fx.port}',
  });
  tools = const GitHubSyncTools();
}

void _stopFixture() {
  PropertyReader.clearOverrides();
  fx.stop();
}

/// Java `GitHub.issue` (#524): the number is carried as a string.
void _issueToolTest() {
  group('GitHubSyncTools issue tool (fixture)', () {
    setUp(_startFixture);
    tearDown(_stopFixture);

    test('github_get_issue hits the issue endpoint with a string number', () {
      final body = jsonDecode(tools.handlers['github_get_issue']!({
        'workspace': 'o',
        'repository': 'r',
        'issueNumber': '42',
      })) as Map<String, dynamic>;
      expect(body['number'], 42);
      final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(sent['method'], 'GET');
      expect(sent['path'], '/repos/o/r/issues/42');
    });
  });
}

/// The issue mutation tools (Dart-side issue family: owner/repo/number):
/// close, create, add labels, remove label — the surface the trackers.js
/// github provider drives for status/labels/create operations.
void _issueMutationTests() {
  group('GitHubSyncTools issue mutations (fixture)', () {
    setUp(_startFixture);
    tearDown(_stopFixture);

    test('github_close_issue PATCHes the issue state', () {
      tools.handlers['github_close_issue']!({
        'owner': 'o',
        'repo': 'r',
        'number': 42,
      });
      final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(sent['method'], 'PATCH');
      expect(sent['path'], '/repos/o/r/issues/42');
      expect(jsonDecode(sent['body'] as String), {'state': 'closed'});
    });

    test('github_add_labels POSTs the label array', () {
      tools.handlers['github_add_labels']!({
        'owner': 'o',
        'repo': 'r',
        'number': 42,
        'labels': ['x', 'y'],
      });
      final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(sent['method'], 'POST');
      expect(sent['path'], '/repos/o/r/issues/42/labels');
      expect(jsonDecode(sent['body'] as String), {
        'labels': ['x', 'y']
      });
    });

    test('github_remove_label DELETEs the label resource', () {
      tools.handlers['github_remove_label']!({
        'owner': 'o',
        'repo': 'r',
        'number': 42,
        'label': 'wip',
      });
      final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(sent['method'], 'DELETE');
      expect(sent['path'], '/repos/o/r/issues/42/labels/wip');
    });
  });
}

/// `github_create_issue` request shape (blank body omitted).
void _createIssueTests() {
  group('GitHubSyncTools issue creation (fixture)', () {
    setUp(_startFixture);
    tearDown(_stopFixture);

    test('github_create_issue POSTs title and omits a blank body', () {
      tools.handlers['github_create_issue']!({
        'owner': 'o',
        'repo': 'r',
        'title': 'New bug',
      });
      var sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(sent['method'], 'POST');
      expect(sent['path'], '/repos/o/r/issues');
      expect(jsonDecode(sent['body'] as String), {'title': 'New bug'});

      tools.handlers['github_create_issue']!({
        'owner': 'o',
        'repo': 'r',
        'title': 'New bug',
        'body': 'It broke',
      });
      sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(
        jsonDecode(sent['body'] as String),
        {'title': 'New bug', 'body': 'It broke'},
      );
    });
  });
}

/// The native PR review tools (Java `GitHub` #495): submit / list /
/// dismiss, with the Java event-DISMISS payload on dismissals.
void _reviewToolTests() {
  group('GitHubSyncTools PR review tools (fixture)', () {
    setUp(_startFixture);
    tearDown(_stopFixture);

    test('github_submit_pr_review POSTs the event and omits a blank body', () {
      tools.handlers['github_submit_pr_review']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '74',
        'event': 'APPROVE',
      });
      var sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(sent['method'], 'POST');
      expect(sent['path'], '/repos/o/r/pulls/74/reviews');
      expect(jsonDecode(sent['body'] as String), {'event': 'APPROVE'});

      tools.handlers['github_submit_pr_review']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '74',
        'event': 'REQUEST_CHANGES',
        'body': 'blocking issues',
      });
      sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(
        jsonDecode(sent['body'] as String),
        {'event': 'REQUEST_CHANGES', 'body': 'blocking issues'},
      );
    });

    test('github_list_pr_reviews GETs the reviews endpoint', () {
      tools.handlers['github_list_pr_reviews']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '74',
      });
      final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(sent['method'], 'GET');
      expect(sent['path'], '/repos/o/r/pulls/74/reviews?per_page=100&page=1');
    });

    test('github_dismiss_pr_review PUTs message with event DISMISS', () {
      tools.handlers['github_dismiss_pr_review']!({
        'workspace': 'o',
        'repository': 'r',
        'pullRequestId': '74',
        'reviewId': '123',
        'message': 'superseded',
      });
      final sent = jsonDecode(fx.lastRequestJson!) as Map<String, dynamic>;
      expect(sent['method'], 'PUT');
      expect(sent['path'], '/repos/o/r/pulls/74/reviews/123/dismissals');
      expect(
        jsonDecode(sent['body'] as String),
        {'message': 'superseded', 'event': 'DISMISS'},
      );
    });
  });
}
