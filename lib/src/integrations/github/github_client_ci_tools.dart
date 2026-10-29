/// CI-status and PR-activity client methods — the Java `GitHub.java` tools
/// the Dart catalog was missing (dm.ai #543 review surface): check runs,
/// commit statuses, repository dispatch, PR comment management, PR
/// activities, filtered PR listing, release assets, and regex commit
/// collection across branches.
part of 'github_client.dart';

/// CI, PR-activity, release-asset, and cross-branch commit methods.
extension GithubCiPrTools on GithubClient {
  /// `github_create_check_run` — POST `repos/{w}/{r}/check-runs`.
  ///
  /// The `output` object is sent when [title] or [summary] is present
  /// (`title` defaults to [name], `summary` to `""`, Java parity); [text]
  /// rides along only when non-blank.
  Future<Map<String, dynamic>> createCheckRun(
    String workspace,
    String repository,
    String name,
    String headSha, {
    String? status,
    String? title,
    String? summary,
    String? text,
    String? externalId,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'head_sha': headSha,
    };
    _ghPutIfNotBlank(body, 'status', status);
    _ghPutIfNotBlank(body, 'external_id', externalId);
    if (title != null || summary != null) {
      body['output'] = {
        'title': title ?? name,
        'summary': summary ?? '',
        if (_ghNotBlank(text)) 'text': text,
      };
    }
    final response = await _http.post(
      'repos/$workspace/$repository/check-runs',
      body: jsonEncode(body),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_update_check_run` — PATCH
  /// `repos/{w}/{r}/check-runs/{checkRunId}`.
  Future<Map<String, dynamic>> updateCheckRun(
    String workspace,
    String repository,
    String checkRunId,
    String status, {
    String? conclusion,
    String? title,
    String? summary,
    String? text,
  }) async {
    final body = <String, dynamic>{'status': status};
    _ghPutIfNotBlank(body, 'conclusion', conclusion);
    if (title != null || summary != null) {
      body['output'] = {
        if (title != null) 'title': title,
        if (summary != null) 'summary': summary,
        if (_ghNotBlank(text)) 'text': text,
      };
    }
    final response = await _http.patch(
      'repos/$workspace/$repository/check-runs/$checkRunId',
      body: jsonEncode(body),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_create_commit_status` — POST
  /// `repos/{w}/{r}/statuses/{sha}`.
  Future<Map<String, dynamic>> createCommitStatus(
    String workspace,
    String repository,
    String sha,
    String state, {
    String? description,
    String? context,
    String? targetUrl,
  }) async {
    final body = <String, dynamic>{'state': state};
    _ghPutIfNotBlank(body, 'description', description);
    _ghPutIfNotBlank(body, 'context', context);
    _ghPutIfNotBlank(body, 'target_url', targetUrl);
    final response = await _http.post(
      'repos/$workspace/$repository/statuses/$sha',
      body: jsonEncode(body),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_delete_pr_comment` — DELETE
  /// `repos/{w}/{r}/issues/comments/{commentId}` (Java: void).
  Future<void> deletePullRequestComment(
    String workspace,
    String repository,
    String commentId,
  ) async {
    await _http.delete(
      'repos/$workspace/$repository/issues/comments/$commentId',
    );
  }

  /// `github_update_pr_comment` — PATCH
  /// `repos/{w}/{r}/issues/comments/{commentId}` with `{"body": text}`.
  Future<Map<String, dynamic>> updatePullRequestComment(
    String workspace,
    String repository,
    String commentId,
    String text,
  ) async {
    final response = await _http.patch(
      'repos/$workspace/$repository/issues/comments/$commentId',
      body: jsonEncode({'body': text}),
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  /// `github_get_pr_activities` — reviews + inline comments + discussion
  /// comments, in Java's aggregation order.
  ///
  /// Review pages come first, then inline review comments
  /// (`pulls/{id}/comments`, 404-tolerant for plain issues), then the
  /// issue-level discussion — comments wrapped as
  /// `{"action": "COMMENTED", "comment": {...}}` (Java
  /// `GitHubCommentActivity` serialization).
  Future<List<dynamic>> pullRequestActivities(
    String workspace,
    String repository,
    String pullRequestId,
  ) async {
    final activities = <dynamic>[];
    activities.addAll(
      await _ghPaginated('repos/$workspace/$repository'
          '/pulls/$pullRequestId/reviews'),
    );
    for (final comment in await _ghPaginated(
      'repos/$workspace/$repository/pulls/$pullRequestId/comments',
      tolerate404: true,
    )) {
      activities.add({'action': 'COMMENTED', 'comment': comment});
    }
    for (final comment in await _ghPaginated(
      'repos/$workspace/$repository/issues/$pullRequestId/comments',
      tolerate404: true,
    )) {
      activities.add({'action': 'COMMENTED', 'comment': comment});
    }
    return activities;
  }

  /// Java state synonyms: `opened`→`open`, `declined`→`closed`.
  static String _normalizePrState(String lowered) => switch (lowered) {
        'opened' => 'open',
        'declined' => 'closed',
        _ => lowered,
      };

  /// `github_list_prs_filtered` — all PRs whose title matches [titleRegex].
  ///
  /// Java `listPullRequestsFiltered`/`pullRequests(checkAllRequests=true)`:
  /// state synonyms normalize (`opened`→`open`, `declined`→`closed`),
  /// `merged` keeps only PRs with a `merged_at` timestamp, and pages are
  /// fetched until exhausted.
  Future<List<Map<String, dynamic>>> listPullRequestsFiltered(
    String workspace,
    String repository,
    String state,
    String titleRegex,
  ) async {
    final normalized = _normalizePrState(state.toLowerCase());
    final isMerged = normalized == 'merged';
    final pattern = RegExp(titleRegex);
    final out = <Map<String, dynamic>>[];
    for (var page = 1;; page++) {
      final body = await _http.get(
        'repos/$workspace/$repository/pulls',
        queryParams: {
          'state': normalized,
          'sort': 'updated',
          'direction': 'desc',
          'per_page': '100',
          'page': '$page',
        },
      );
      final decoded = jsonDecode(body);
      if (decoded is! List || decoded.isEmpty) break;
      if (_collectMatchingPrPage(decoded, isMerged, pattern, out)) break;
    }
    return out;
  }

  /// Appends one decoded page's PRs matching [pattern] (merged-only when
  /// [isMerged]) into [out]; returns whether the page was partial (the
  /// pagination loop's stop condition).
  static bool _collectMatchingPrPage(
    List<Object?> decoded,
    bool isMerged,
    RegExp pattern,
    List<Map<String, dynamic>> out,
  ) {
    for (final pr in decoded) {
      if (pr is! Map<String, dynamic>) continue;
      if (isMerged && pr['merged_at'] == null) continue;
      final title = pr['title'] as String? ?? '';
      if (pattern.hasMatch(title)) out.add(pr);
    }
    return decoded.length < 100;
  }

  /// `github_get_workflow_run` — GET
  /// `repos/{w}/{r}/actions/runs/{runId}`.
  Future<Map<String, dynamic>> getWorkflowRun(
    String workspace,
    String repository,
    String runId,
  ) async {
    final body =
        await _http.get('repos/$workspace/$repository/actions/runs/$runId');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// `github_repository_dispatch` — POST
  /// `repos/{w}/{r}/dispatches`.
  ///
  /// [clientPayload] is a JSON object string parsed into
  /// `client_payload` (Java parses it eagerly, so invalid JSON throws).
  Future<dynamic> repositoryDispatch(
    String workspace,
    String repository,
    String eventType, [
    String? clientPayload,
  ]) async {
    final body = <String, dynamic>{'event_type': eventType};
    final payload = clientPayload?.trim() ?? '';
    if (payload.isNotEmpty) body['client_payload'] = jsonDecode(payload);
    final response = await _http.post(
      'repos/$workspace/$repository/dispatches',
      body: jsonEncode(body),
    );
    return response.isEmpty ? const {} : jsonDecode(response);
  }

  /// `github_list_release_assets` — GET
  /// `repos/{w}/{r}/releases/{releaseId}/assets`.
  Future<List<dynamic>> listReleaseAssets(
    String workspace,
    String repository,
    String releaseId,
  ) async {
    final body = await _http.get(
      'repos/$workspace/$repository/releases/$releaseId/assets',
    );
    return jsonDecode(body) as List<dynamic>;
  }

  /// `github_delete_release_asset` — DELETE
  /// `repos/{w}/{r}/releases/assets/{assetId}` (Java: void).
  Future<void> deleteReleaseAsset(
    String workspace,
    String repository,
    String assetId,
  ) async {
    await _http.delete(
      'repos/$workspace/$repository/releases/assets/$assetId',
    );
  }

  /// `github_get_commits_from_branches` — commits from every branch whose
  /// name matches [branchNameRegex], de-duplicated by SHA.
  ///
  /// Java `getCommitsFromBranchesByRegex`: branches paginate 100 per page,
  /// the regex is an unanchored `find()`, and each branch's commits are
  /// fetched with `sha=<branch>` plus `since=<date>T00:00:00Z` when
  /// [since] is present.
  Future<List<dynamic>> getCommitsFromBranches(
    String workspace,
    String repository,
    String branchNameRegex, [
    String? since,
  ]) async {
    final pattern = RegExp(branchNameRegex);
    final seenShas = <String>{};
    final out = <dynamic>[];
    for (final branch in await _ghPaginated(
      'repos/$workspace/$repository/branches',
    )) {
      final name = branch['name'] as String?;
      if (name == null || !pattern.hasMatch(name)) continue;
      for (final commit in await _ghBranchCommits(
        workspace,
        repository,
        name,
        since,
      )) {
        final sha = commit['sha'] as String?;
        if (sha == null || !seenShas.add(sha)) continue;
        out.add(commit);
      }
    }
    return out;
  }

  /// All pages of a branch's commit list (Java `getCommitsFromBranch`).
  Future<List<dynamic>> _ghBranchCommits(
    String workspace,
    String repository,
    String branch,
    String? since,
  ) async {
    final out = <dynamic>[];
    for (var page = 1;; page++) {
      final query = <String, dynamic>{
        'sha': branch,
        'per_page': '100',
        'page': '$page',
        if (_ghNotBlank(since)) 'since': '${since!.trim()}T00:00:00Z',
      };
      final body = await _http.get(
        'repos/$workspace/$repository/commits',
        queryParams: query,
      );
      final decoded = jsonDecode(body);
      if (decoded is! List || decoded.isEmpty) break;
      out.addAll(decoded);
      if (decoded.length < 100) break;
    }
    return out;
  }

  /// GETs all pages of a JSON-array endpoint (100 per page).
  ///
  /// With [tolerate404] a 404 simply ends the listing (plain issues have no
  /// `pulls/{id}/comments` endpoint — Java `GitHubIssues` parity); any
  /// other failure rethrows.
  Future<List<Map<String, dynamic>>> _ghPaginated(
    String endpoint, {
    bool tolerate404 = false,
  }) async {
    final out = <Map<String, dynamic>>[];
    for (var page = 1;; page++) {
      final String body;
      try {
        body = await _http.get(
          endpoint,
          queryParams: {'per_page': '100', 'page': '$page'},
        );
      } on DioException catch (e) {
        if (tolerate404 && e.response?.statusCode == 404) break;
        rethrow;
      }
      final decoded = jsonDecode(body);
      if (decoded is! List) break;
      out.addAll(decoded.whereType<Map<String, dynamic>>());
      if (decoded.length < 100) break;
    }
    return out;
  }
}

/// Whether [value] is non-null and not whitespace-only.
bool _ghNotBlank(String? value) => value != null && value.trim().isNotEmpty;

/// Sets `body[key] = value.trim()` when [value] is non-blank (Java
/// `!value.trim().isEmpty()` guards).
void _ghPutIfNotBlank(Map<String, dynamic> body, String key, String? value) {
  if (_ghNotBlank(value)) body[key] = value!.trim();
}
