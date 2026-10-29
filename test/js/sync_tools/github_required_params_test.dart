import 'package:dmtools/src/js/sync_tools/github_sync_tools.dart';
import 'package:dmtools/src/js/sync_tools/sync_required_params.dart';
import 'package:test/test.dart';

import 'required_params_test_support.dart';

/// Required-parameter validation for [GitHubSyncTools] — Java
/// MCPToolProcessor parity (P6-VCS-16).
void main() {
  _missingParamOrderTests();
  _aliasAndAcceptedNameTests();
}

void _missingParamOrderTests() {
  const tools = GitHubSyncTools();
  group('GitHubSyncTools required-param validation (Java order)', () {
    withUnconfiguredSyncTools(
      tools.handlers,
      {'SOURCE_GITHUB_TOKEN': ''},
      (callJson, _) {
        test('first and subsequent missing params follow Java order', () {
          expect(
            callJson('github_add_pr_comment'),
            missingParamError('workspace'),
          );
          expect(
            callJson('github_add_pr_comment', {
              'workspace': 'o',
              'repository': 'r',
              'pullRequestId': '7',
            }),
            missingParamError('text'),
          );
        });

        test('multi-param chain, Java casing, and pre-config order', () {
          expect(
            callJson('github_dismiss_pr_review', {
              'workspace': 'o',
              'pullRequestId': '7',
              'reviewId': '1',
            }),
            missingParamError('repository'),
          );
          expect(
            callJson('github_dismiss_pr_review', {
              'workspace': 'o',
              'repository': 'r',
              'pullRequestId': '7',
              'reviewId': '1',
            }),
            missingParamError('message'),
          );
          expect(
            callJson('github_get_pr_diff', {
              'workspace': 'o',
              'repository': 'r',
              'nothing': 'x',
            }),
            missingParamError('pullRequestID'),
          );
          expect(callJson('github_get_pr'), missingParamError('workspace'));
        });
      },
    );
  });
}

void _aliasAndAcceptedNameTests() {
  const tools = GitHubSyncTools();
  group('GitHubSyncTools required-param validation (aliases)', () {
    withUnconfiguredSyncTools(
      tools.handlers,
      {'SOURCE_GITHUB_TOKEN': ''},
      (_, callRaw) {
        test('Dart spellings, threadId alias, and parameterless tools', () {
          expect(
            callRaw('github_get_pr_diff', {
              'workspace': 'o',
              'repository': 'r',
              'pullRequestId': '7',
            }),
            satisfiesRequiredParams,
          );
          expect(
            callRaw('github_reply_to_pr_thread', {
              'workspace': 'o',
              'repository': 'r',
              'pullRequestId': '7',
              'threadId': '1',
              'text': 'hi',
            }),
            satisfiesRequiredParams,
          );
          expect(callRaw('github_list_branches'), satisfiesRequiredParams);
        });

        test('kGithubRequiredParams keys are all registered handlers', () {
          for (final name in kGithubRequiredParams.keys) {
            expect(tools.handlers, contains(name), reason: name);
          }
        });
      },
    );
  });
}
