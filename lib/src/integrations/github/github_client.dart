/// High-level GitHub API client — ports the GitHub subset of the Java MCP tools.
///
/// Each method corresponds to a `@MCPTool`-annotated method on the Java
/// integration client. Transport is delegated to [GithubHttpClient]; this
/// layer only shapes requests and parses JSON into typed results.
///
/// The issue family (Java `GitHubIssues.java`, dm.ai #543) resolves issue
/// references from either explicit parts or a composite
/// `owner/repo#123` key, falling back to the configured
/// `SOURCE_GITHUB_WORKSPACE` / `SOURCE_GITHUB_REPOSITORY` defaults.
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../config/property_reader.dart';
import '../../config/property_reader_getters.dart';
import 'github_http_client.dart';

part 'github_client_issue_tools.dart';
part 'github_client_ci_tools.dart';

/// GitHub API methods exposed to the MCP tool runtime.
class GithubClient {
  final GithubHttpClient _http;

  /// Creates a client backed by [_http].
  GithubClient(this._http);

  /// `github_test` — connectivity check via GET `/user`.
  ///
  /// Returns the GitHub user profile on success, or an error map on failure.
  Future<Map<String, dynamic>> testConnection() async {
    try {
      final user = await _fetchUser();
      return {
        'success': true,
        'message': 'GitHub connection successful',
        'user': user['login'] ?? '',
      };
    } on Object catch (e) {
      return {
        'success': false,
        'message': 'GitHub connection failed',
        'error': e.toString(),
      };
    }
  }

  /// Fetches the authenticated user from GET `/user`.
  Future<Map<String, dynamic>> _fetchUser() async {
    final body = await _http.get('user');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_get_pr` — GET `/repos/{owner}/{repo}/pulls/{number}`.
  Future<Map<String, dynamic>> getPr(
    String owner,
    String repo,
    int number,
  ) async {
    final body = await _http.get('repos/$owner/$repo/pulls/$number');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_list_prs` — GET `/repos/{owner}/{repo}/pulls`.
  ///
  /// [state] defaults to `open` (GitHub's default) when omitted. `open`
  /// walks every page (gh-388: open counts are bounded and SM sweeps need
  /// completeness); other states return the first page (up to 100) only.
  Future<List<Map<String, dynamic>>> listPrs(
    String owner,
    String repo, [
    String? state,
  ]) async {
    final query = {'state': state ?? 'open'};
    final path = 'repos/$owner/$repo/pulls';
    if (query['state'] == 'open') return _pagesFrom(path, 1, query);
    final body = await _http.get(
      path,
      queryParams: {...query, 'per_page': '100', 'page': '1'},
    );
    return _decodeList(body);
  }

  /// GETs every `per_page=100` page (from [startPage]) of the JSON-array endpoint [path]
  /// (gh-388): stops on a short or empty page; a later-page failure
  /// keeps the pages already collected.
  Future<List<Map<String, dynamic>>> _pagesFrom(
    String path,
    int startPage, [
    Map<String, String> query = const {},
  ]) async {
    final out = <Map<String, dynamic>>[];
    for (var page = startPage;; page++) {
      final List<Map<String, dynamic>> items;
      try {
        items = _decodeList(await _http.get(
          path,
          queryParams: {...query, 'per_page': '100', 'page': '$page'},
        ));
      } on Object {
        if (page == 1) rethrow;
        break;
      }
      out.addAll(items);
      if (items.length < 100) break;
    }
    return out;
  }

  /// `github_create_comment` — POST `/repos/{owner}/{repo}/issues/{number}/comments`.
  ///
  /// Pull-request comments are posted through the issues endpoint, matching
  /// the GitHub REST API (PRs are issues). Java `GitHubIssues.createComment`
  /// (#543): the reference resolves from explicit parts, a composite [key],
  /// or the configured defaults.
  Future<Map<String, dynamic>> createComment(
    String? workspace,
    String? repository,
    String? pullRequestId,
    String body, {
    String? key,
  }) async {
    final ref = resolveGhIssueRef(
      key,
      workspace,
      repository,
      _ghIntOrNull(pullRequestId),
    );
    return _postToIssue(ref, '/comments', {'body': body});
  }

  /// POSTs [payload] to the issue endpoint [suffix] for [ref] and decodes
  /// the JSON object response (shared by the issue-family POST calls).
  Future<Map<String, dynamic>> _postToIssue(
    GhIssueRef ref,
    String suffix,
    Map<String, dynamic> payload,
  ) async {
    final response = await _http.post(
      'repos/${ref.owner}/${ref.repo}/issues/${ref.number}$suffix',
      body: jsonEncode(payload),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// PATCHes the issue [state] for [ref] (shared by close/reopen).
  Future<Map<String, dynamic>> _patchIssueState(
    GhIssueRef ref,
    String state,
  ) async {
    final response = await _http.patch(
      'repos/${ref.owner}/${ref.repo}/issues/${ref.number}',
      body: jsonEncode({'state': state}),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_get_issue` — GET `/repos/{owner}/{repo}/issues/{number}`.
  ///
  /// Java `GitHubIssues.issue` (#543): the reference resolves from explicit
  /// parts, a composite [key] (`owner/repo#123` or a bare number), or the
  /// configured workspace/repository defaults.
  Future<Map<String, dynamic>> getIssue(
    String? workspace,
    String? repository,
    String? issueNumber, {
    String? key,
  }) async {
    final ref = resolveGhIssueRef(
      key,
      workspace,
      repository,
      _ghIntOrNull(issueNumber),
    );
    final body = await _http.get(
      'repos/${ref.owner}/${ref.repo}/issues/${ref.number}',
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_submit_pr_review` — POST
  /// `/repos/{owner}/{repo}/pulls/{id}/reviews` (Java #495).
  ///
  /// [body] is only sent when non-blank (Java parity: the payload omits an
  /// empty summary so COMMENT-only reviews stay valid).
  Future<Map<String, dynamic>> submitPullRequestReview(
    String workspace,
    String repository,
    String pullRequestId,
    String event,
    String? body,
  ) async {
    final payload = <String, dynamic>{'event': event};
    if (body != null && body.trim().isNotEmpty) {
      payload['body'] = body;
    }
    final response = await _http.post(
      'repos/$workspace/$repository/pulls/$pullRequestId/reviews',
      body: jsonEncode(payload),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_list_pr_reviews` — GET
  /// `/repos/{owner}/{repo}/pulls/{id}/reviews` (Java #495). An empty API
  /// response comes back as an empty list (Java returns `[]`).
  Future<List<Map<String, dynamic>>> listPullRequestReviews(
    String workspace,
    String repository,
    String pullRequestId,
  ) async {
    final path = 'repos/$workspace/$repository/pulls/$pullRequestId/reviews';
    final body =
        await _http.get(path, queryParams: {'per_page': '100', 'page': '1'});
    if (body.trim().isEmpty) return const [];
    final decoded = jsonDecode(body);
    if (decoded is! List) return const [];
    final first = decoded.cast<Map<String, dynamic>>().toList();
    if (first.length < 100) return first;
    return [...first, ...await _pagesFrom(path, 2)];
  }

  /// `github_dismiss_pr_review` — PUT
  /// `/repos/{owner}/{repo}/pulls/{id}/reviews/{reviewId}/dismissals`
  /// (Java #495). Always sends `event: DISMISS` alongside the message.
  Future<Map<String, dynamic>> dismissPullRequestReview(
    String workspace,
    String repository,
    String pullRequestId,
    String reviewId,
    String message,
  ) async {
    final response = await _http.put(
      'repos/$workspace/$repository/pulls/$pullRequestId'
      '/reviews/$reviewId/dismissals',
      body: jsonEncode({'message': message, 'event': 'DISMISS'}),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_create_pr` — POST `/repos/{owner}/{repo}/pulls`.
  Future<Map<String, dynamic>> createPr(
    String owner,
    String repo,
    String title,
    String head,
    String base,
  ) async {
    final response = await _http.post(
      'repos/$owner/$repo/pulls',
      body: jsonEncode({
        'title': title,
        'head': head,
        'base': base,
      }),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_merge_pr` — PUT `/repos/{owner}/{repo}/pulls/{number}/merge`.
  Future<Map<String, dynamic>> mergePr(
    String owner,
    String repo,
    int number,
  ) async {
    final response = await _http.put('repos/$owner/$repo/pulls/$number/merge');
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_close_pr` — PATCH `/repos/{owner}/{repo}/pulls/{number}`.
  Future<Map<String, dynamic>> closePr(
    String owner,
    String repo,
    int number,
  ) async {
    return _setPrState(owner, repo, number, 'closed');
  }

  /// `github_reopen_pr` — PATCH `/repos/{owner}/{repo}/pulls/{number}`.
  Future<Map<String, dynamic>> reopenPr(
    String owner,
    String repo,
    int number,
  ) async {
    return _setPrState(owner, repo, number, 'open');
  }

  /// PATCHes the PR [state] via the pulls endpoint (shared by close/reopen).
  Future<Map<String, dynamic>> _setPrState(
    String owner,
    String repo,
    int number,
    String state,
  ) async {
    final response = await _http.patch(
      'repos/$owner/$repo/pulls/$number',
      body: jsonEncode({'state': state}),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_get_pr_diff` — GET `/repos/{owner}/{repo}/pulls/{number}`
  /// requesting the `application/vnd.github.diff` media type.
  ///
  /// Returns the raw unified diff text (not JSON).
  Future<String> getPrDiff(
    String owner,
    String repo,
    int number,
  ) async {
    return _http.get(
      'repos/$owner/$repo/pulls/$number',
      extra: {'Accept': 'application/vnd.github.diff'},
    );
  }

  /// `github_get_pr_files` — GET `/repos/{owner}/{repo}/pulls/{number}/files`.
  Future<List<Map<String, dynamic>>> getPrFiles(
    String owner,
    String repo,
    int number,
  ) async {
    final body = await _http.get('repos/$owner/$repo/pulls/$number/files');
    return _decodeList(body);
  }

  /// `github_create_review` — POST `/repos/{owner}/{repo}/pulls/{number}/reviews`.
  ///
  /// [event] is the GitHub review action (`APPROVE`, `REQUEST_CHANGES`,
  /// `COMMENT`).
  Future<Map<String, dynamic>> createReview(
    String owner,
    String repo,
    int number,
    String body,
    String event,
  ) async {
    final response = await _http.post(
      'repos/$owner/$repo/pulls/$number/reviews',
      body: jsonEncode({'body': body, 'event': event}),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_list_branches` — every page of `/repos/{owner}/{repo}/branches`.
  Future<List<Map<String, dynamic>>> listBranches(
    String owner,
    String repo,
  ) async {
    return _pagesFrom('repos/$owner/$repo/branches', 1);
  }

  /// `github_create_branch` — POST `/repos/{owner}/{repo}/git/refs`.
  ///
  /// Creates `refs/heads/{branch}` pointing at [fromSha].
  Future<Map<String, dynamic>> createBranch(
    String owner,
    String repo,
    String branch,
    String fromSha,
  ) async {
    final response = await _http.post(
      'repos/$owner/$repo/git/refs',
      body: jsonEncode({'ref': 'refs/heads/$branch', 'sha': fromSha}),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_get_file_content` — GET `/repos/{owner}/{repo}/contents/{path}`.
  ///
  /// [ref] optionally names a branch, tag, or commit SHA.
  Future<Map<String, dynamic>> getFileContent(
    String owner,
    String repo,
    String path, [
    String? ref,
  ]) async {
    final body = await _http.get(
      'repos/$owner/$repo/contents/$path',
      queryParams: ref == null ? null : {'ref': ref},
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_update_file` — PUT `/repos/{owner}/{repo}/contents/{path}`.
  ///
  /// [content] is UTF-8 text, base64-encoded here as the Contents API requires.
  /// [sha] is the blob SHA of the file being replaced.
  Future<Map<String, dynamic>> updateFile(
    String owner,
    String repo,
    String path,
    String content,
    String message,
    String sha,
  ) async {
    final response = await _http.put(
      'repos/$owner/$repo/contents/$path',
      body: jsonEncode({
        'message': message,
        'content': base64Encode(utf8.encode(content)),
        'sha': sha,
      }),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_list_releases` — GET `/repos/{owner}/{repo}/releases`.
  Future<List<Map<String, dynamic>>> listReleases(
    String owner,
    String repo,
  ) async {
    final body = await _http.get('repos/$owner/$repo/releases');
    return _decodeList(body);
  }

  /// `github_get_release` — GET `/repos/{owner}/{repo}/releases/tags/{tag}`.
  Future<Map<String, dynamic>> getRelease(
    String owner,
    String repo,
    String tag,
  ) async {
    final body = await _http.get('repos/$owner/$repo/releases/tags/$tag');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_create_release` — POST `/repos/{owner}/{repo}/releases`.
  ///
  /// [body] optionally sets the release description (markdown).
  Future<Map<String, dynamic>> createRelease(
    String owner,
    String repo,
    String tagName, [
    String? body,
  ]) =>
      _postWithOptionalBody(
        'repos/$owner/$repo/releases',
        {'tag_name': tagName},
        body,
      );

  /// `github_delete_branch` — DELETE
  /// `/repos/{owner}/{repo}/git/refs/heads/{branch}`.
  Future<Map<String, dynamic>> deleteBranch(
    String owner,
    String repo,
    String branch,
  ) async {
    final body = await _http.delete(
      'repos/$owner/$repo/git/refs/heads/$branch',
    );
    return _decodeEmptyOk(body);
  }

  /// `github_get_commit` — GET `/repos/{owner}/{repo}/commits/{sha}`.
  Future<Map<String, dynamic>> getCommit(
    String owner,
    String repo,
    String sha,
  ) async {
    final body = await _http.get('repos/$owner/$repo/commits/$sha');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_list_commits` — GET `/repos/{owner}/{repo}/commits`.
  ///
  /// [sha] optionally scopes the list to a branch or commit SHA.
  Future<List<Map<String, dynamic>>> listCommits(
    String owner,
    String repo, [
    String? sha,
  ]) async {
    final body = await _http.get(
      'repos/$owner/$repo/commits',
      queryParams: sha == null ? null : {'sha': sha},
    );
    return _decodeList(body);
  }

  /// `github_create_issue` — POST `/repos/{owner}/{repo}/issues`.
  ///
  /// Java `GitHubIssues.createIssue` (#543): [key] optionally carries the
  /// composite project reference `owner/repo`; blank parts fall back to the
  /// configured defaults.
  Future<Map<String, dynamic>> createIssue(
    String? owner,
    String? repo,
    String title, {
    String? body,
    String? key,
  }) async {
    final resolved = _resolveProjectRef(key, owner, repo);
    if (resolved == null) {
      throw ArgumentError(
        "github_create_issue requires owner/repo or a composite "
        "key/project 'owner/repo'.",
      );
    }
    final response = await _http.post(
      'repos/${resolved.$1}/${resolved.$2}/issues',
      body: jsonEncode({
        'title': title,
        if (body != null) 'body': body,
      }),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_close_issue` — PATCH `/repos/{owner}/{repo}/issues/{number}`.
  ///
  /// Java `GitHubIssues.closeIssue` (#543): accepts a composite [key].
  Future<Map<String, dynamic>> closeIssue(
    String? owner,
    String? repo,
    int? number, {
    String? key,
  }) async {
    final ref = resolveGhIssueRef(key, owner, repo, number);
    return _patchIssueState(ref, 'closed');
  }

  /// `github_add_labels` — POST
  /// `/repos/{owner}/{repo}/issues/{number}/labels`.
  ///
  /// Java `GitHubIssues.addLabels` (#543): accepts a composite [key].
  Future<List<Map<String, dynamic>>> addLabels(
    String? owner,
    String? repo,
    int? number,
    List<String> labels, {
    String? key,
  }) async {
    final ref = resolveGhIssueRef(key, owner, repo, number);
    final response = await _http.post(
      'repos/${ref.owner}/${ref.repo}/issues/${ref.number}/labels',
      body: jsonEncode({'labels': labels}),
    );
    return _decodeList(response);
  }

  /// `github_remove_label` — DELETE
  /// `/repos/{owner}/{repo}/issues/{number}/labels/{label}`.
  ///
  /// Java `GitHubIssues.removeLabel` (#543): accepts a composite [key].
  Future<Map<String, dynamic>> removeLabel(
    String? owner,
    String? repo,
    int? number,
    String label, {
    String? key,
  }) async {
    final ref = resolveGhIssueRef(key, owner, repo, number);
    final body = await _http.delete(
      'repos/${ref.owner}/${ref.repo}/issues/${ref.number}'
      '/labels/${Uri.encodeComponent(label)}',
    );
    return _decodeEmptyOk(body);
  }

  /// `github_get_repo` — GET `/repos/{owner}/{repo}`.
  Future<Map<String, dynamic>> getRepo(String owner, String repo) async {
    final body = await _http.get('repos/$owner/$repo');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_update_pr` — PATCH `/repos/{owner}/{repo}/pulls/{number}`.
  ///
  /// Only the fields provided are sent, so [title] and [body] may each be
  /// omitted to leave that field unchanged.
  Future<Map<String, dynamic>> updatePullRequest(
    String owner,
    String repo,
    int number, [
    String? title,
    String? body,
  ]) async {
    final payload = <String, dynamic>{
      if (title != null) 'title': title,
      if (body != null) 'body': body,
    };
    final response = await _http.patch(
      'repos/$owner/$repo/pulls/$number',
      body: jsonEncode(payload),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_request_reviewers` — POST
  /// `/repos/{owner}/{repo}/pulls/{number}/requested_reviewers`.
  Future<Map<String, dynamic>> requestReviewers(
    String owner,
    String repo,
    int number,
    List<String> reviewers,
  ) async {
    final response = await _http.post(
      'repos/$owner/$repo/pulls/$number/requested_reviewers',
      body: jsonEncode({'reviewers': reviewers}),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_dismiss_review` — PUT
  /// `/repos/{owner}/{repo}/pulls/{number}/reviews/{reviewId}/dismissals`.
  Future<Map<String, dynamic>> dismissReview(
    String owner,
    String repo,
    int number,
    int reviewId,
    String message,
  ) async {
    final response = await _http.put(
      'repos/$owner/$repo/pulls/$number/reviews/$reviewId/dismissals',
      body: jsonEncode({'message': message}),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_get_workflow_runs` — GET `/repos/{owner}/{repo}/actions/runs`.
  Future<Map<String, dynamic>> getWorkflowRuns(
      String owner, String repo) async {
    final body = await _http.get('repos/$owner/$repo/actions/runs');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_rerun_workflow` — POST
  /// `/repos/{owner}/{repo}/actions/runs/{runId}/rerun`.
  ///
  /// Returns an empty map on GitHub's empty 201 response body.
  Future<Map<String, dynamic>> reRunWorkflow(
    String owner,
    String repo,
    int runId,
  ) async {
    final body = await _http.post(
      'repos/$owner/$repo/actions/runs/$runId/rerun',
    );
    return _decodeEmptyOk(body);
  }

  /// `github_get_check_runs` — GET
  /// `/repos/{owner}/{repo}/commits/{ref}/check-runs`.
  Future<Map<String, dynamic>> getCheckRuns(
    String owner,
    String repo,
    String ref,
  ) async {
    final body = await _http.get('repos/$owner/$repo/commits/$ref/check-runs');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_get_tree` — GET `/repos/{owner}/{repo}/git/trees/{ref}`.
  ///
  /// Requests the full recursive tree (`recursive=1`).
  Future<Map<String, dynamic>> getTree(
    String owner,
    String repo,
    String ref,
  ) async {
    final body = await _http.get(
      'repos/$owner/$repo/git/trees/$ref',
      queryParams: {'recursive': '1'},
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_get_workflows` — GET
  /// `/repos/{owner}/{repo}/actions/workflows`.
  Future<Map<String, dynamic>> getWorkflows(String owner, String repo) async {
    final body = await _http.get('repos/$owner/$repo/actions/workflows');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_enable_workflow` — PUT
  /// `/repos/{owner}/{repo}/actions/workflows/{workflowId}/enable`.
  ///
  /// Returns an empty map on GitHub's 204 response.
  Future<Map<String, dynamic>> enableWorkflow(
    String owner,
    String repo,
    int workflowId,
  ) async {
    final body = await _http.put(
      'repos/$owner/$repo/actions/workflows/$workflowId/enable',
    );
    return _decodeEmptyOk(body);
  }

  /// `github_disable_workflow` — PUT
  /// `/repos/{owner}/{repo}/actions/workflows/{workflowId}/disable`.
  ///
  /// Returns an empty map on GitHub's 204 response.
  Future<Map<String, dynamic>> disableWorkflow(
    String owner,
    String repo,
    int workflowId,
  ) async {
    final body = await _http.put(
      'repos/$owner/$repo/actions/workflows/$workflowId/disable',
    );
    return _decodeEmptyOk(body);
  }

  /// `github_get_codeowners` — GET
  /// `/repos/{owner}/{repo}/contents/.github/CODEOWNERS`.
  Future<Map<String, dynamic>> getCodeowners(String owner, String repo) async {
    final body =
        await _http.get('repos/$owner/$repo/contents/.github/CODEOWNERS');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_add_collaborator` — PUT
  /// `/repos/{owner}/{repo}/collaborators/{username}`.
  ///
  /// [permission] sets the collaboration level (`push`, `pull`, `admin`,
  /// `maintain`, `triage`). Returns the invitation or an empty map on a 204.
  Future<Map<String, dynamic>> addCollaborator(
    String owner,
    String repo,
    String username,
    String permission,
  ) async {
    final response = await _http.put(
      'repos/$owner/$repo/collaborators/$username',
      body: jsonEncode({'permission': permission}),
    );
    return _decodeEmptyOk(response);
  }

  /// `github_remove_collaborator` — DELETE
  /// `/repos/{owner}/{repo}/collaborators/{username}`.
  ///
  /// Returns an empty map on GitHub's 204 response.
  Future<Map<String, dynamic>> removeCollaborator(
    String owner,
    String repo,
    String username,
  ) async {
    final body = await _http.delete(
      'repos/$owner/$repo/collaborators/$username',
    );
    return _decodeEmptyOk(body);
  }

  /// POSTs [endpoint] with [base] merged with an optional `body` field.
  Future<Map<String, dynamic>> _postWithOptionalBody(
    String endpoint,
    Map<String, dynamic> base,
    String? body,
  ) async {
    final payload = Map<String, dynamic>.from(base);
    if (body != null) payload['body'] = body;
    final response = await _http.post(endpoint, body: jsonEncode(payload));
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// Decodes a DELETE response body, tolerating GitHub's empty 204 body.
  Map<String, dynamic> _decodeEmptyOk(String body) =>
      body.isEmpty ? {} : jsonDecode(body) as Map<String, dynamic>;

  /// Decodes a JSON array [body] into a list of maps.
  static List<Map<String, dynamic>> _decodeList(String body) {
    final decoded = jsonDecode(body) as List;
    return List<Map<String, dynamic>>.from(
      decoded.map((e) => e as Map<String, dynamic>),
    );
  }
}
