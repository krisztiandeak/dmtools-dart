import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dmtools/dmtools.dart';
import 'package:test/test.dart';

import 'github_test_support.dart';

/// gh-388: the MCP-side GitHub list tools walk `per_page=100` pages.
String _page(int page, int count) => jsonEncode([
      for (var i = 0; i < count; i++) {'id': page * 1000 + i}
    ]);

/// Full page 1, 2-item page 2; throws on page 2 when [failLater].
String Function(RequestOptions) _paged({bool failLater = false}) => (o) {
      final page = o.queryParameters['page'];
      if (page == '1') return _page(1, 100);
      if (failLater) throw StateError('page boom');
      return _page(2, 2);
    };

void main() {
  tearDown(PropertyReader.clearOverrides);

  group('GithubClient pagination (gh-388)', () {
    test('listBranches walks every page', () async {
      final f = mockGithub(_paged());
      expect(await f.client.listBranches('o', 'r'), hasLength(102));
      expect(f.adapter.calls.map((c) => c.queryParameters['page']), ['1', '2']);
      expect(f.adapter.calls.first.queryParameters['per_page'], '100');
    });

    test('listPrs open walks every page', () async {
      final f = mockGithub(_paged());
      expect(await f.client.listPrs('o', 'r'), hasLength(102));
      expect(f.adapter.calls, hasLength(2));
    });

    test('listPrs closed keeps the first page only', () async {
      final f = mockGithub(_paged());
      expect(await f.client.listPrs('o', 'r', 'closed'), hasLength(100));
      expect(f.adapter.calls.single.queryParameters['state'], 'closed');
    });

    test('listPullRequestReviews walks every page', () async {
      final f = mockGithub(_paged());
      expect(
        await f.client.listPullRequestReviews('o', 'r', '7'),
        hasLength(102),
      );
      expect(f.adapter.calls, hasLength(2));
    });
  });
  _edgeTests();
}

/// Failures, short pages, and empty/non-list bodies.
void _edgeTests() {
  group('GithubClient pagination edges (gh-388)', () {
    test('a later-page failure keeps the pages already collected', () async {
      final f = mockGithub(_paged(failLater: true));
      expect(await f.client.listBranches('o', 'r'), hasLength(100));
      final r = mockGithub(_paged(failLater: true));
      expect(
        await r.client.listPullRequestReviews('o', 'r', '7'),
        hasLength(100),
      );
    });

    test('a page-1 failure propagates', () async {
      final f = mockGithub((_) => throw StateError('boom'));
      await expectLater(f.client.listBranches('o', 'r'), throwsA(anything));
    });

    test('a short first page is exactly one request', () async {
      final f = mockGithub((_) => _page(1, 3));
      expect(await f.client.listBranches('o', 'r'), hasLength(3));
      expect(f.adapter.calls, hasLength(1));
    });

    test('empty and non-list review bodies come back empty', () async {
      expect(
        await mockGithub((_) => '')
            .client
            .listPullRequestReviews('o', 'r', '7'),
        isEmpty,
      );
      expect(
        await mockGithub((_) => '{"message":"x"}')
            .client
            .listPullRequestReviews('o', 'r', '7'),
        isEmpty,
      );
    });
  });
}
