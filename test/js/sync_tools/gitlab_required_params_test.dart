import 'package:dmtools/src/js/sync_tools/gitlab_sync_tools.dart';
import 'package:dmtools/src/js/sync_tools/sync_required_params.dart';
import 'package:test/test.dart';

import 'required_params_test_support.dart';

/// Required-parameter validation for [GitLabSyncTools] — Java
/// MCPToolProcessor parity (P6-VCS-16).
void main() {
  _gitlabOrderTests();
  _gitlabAliasTests();
}

void _gitlabOrderTests() {
  const tools = GitLabSyncTools();
  group('GitLabSyncTools required-param validation (Java order)', () {
    withUnconfiguredSyncTools(
      tools.handlers,
      {'GITLAB_BASE_PATH': '', 'GITLAB_TOKEN': ''},
      (callJson, _) {
        test('pipeline trigger validates workspace then ref', () {
          expect(
            callJson('gitlab_trigger_pipeline'),
            missingParamError('workspace'),
          );
          expect(
            callJson('gitlab_trigger_pipeline', {
              'workspace': 'g',
              'repository': 'r',
            }),
            missingParamError('ref'),
          );
        });

        test('release asset chain and MR pre-config validation', () {
          expect(
            callJson('gitlab_download_release_asset', {
              'workspace': 'g',
              'tagName': 'v1',
              'assetName': 'a',
            }),
            missingParamError('repository'),
          );
          expect(
            callJson('gitlab_download_release_asset', {
              'workspace': 'g',
              'repository': 'r',
              'tagName': 'v1',
              'assetName': 'a',
            }),
            missingParamError('targetFilePath'),
          );
          expect(callJson('gitlab_get_mr'), missingParamError('workspace'));
        });
      },
    );
  });
}

void _gitlabAliasTests() {
  const tools = GitLabSyncTools();
  group('GitLabSyncTools required-param validation (aliases)', () {
    withUnconfiguredSyncTools(
      tools.handlers,
      {'GITLAB_BASE_PATH': '', 'GITLAB_TOKEN': ''},
      (_, callRaw) {
        test('threadId and body aliases satisfy discussionId and text', () {
          expect(
            callRaw('gitlab_resolve_mr_thread', {
              'workspace': 'g',
              'repository': 'r',
              'pullRequestId': '7',
              'threadId': 'abc',
            }),
            satisfiesRequiredParams,
          );
          expect(
            callRaw('gitlab_create_mr_note', {
              'workspace': 'g',
              'repository': 'r',
              'pullRequestId': '7',
              'body': 'hi',
            }),
            satisfiesRequiredParams,
          );
        });

        test('kGitlabRequiredParams maps onto registered handlers', () {
          final registered =
              kGitlabRequiredParams.keys.where(tools.handlers.containsKey);
          expect(registered, isNotEmpty);
        });
      },
    );
  });
}
