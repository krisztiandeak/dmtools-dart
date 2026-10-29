/// Unit + integration tests for [SyncRetryPolicy] and the retry wiring in
/// [SyncHttpClient] (gh-191, P6-JSY-18 — Java `RetryPolicy` parity).
library;

import 'dart:convert';
import 'dart:math';

import 'package:dmtools/src/js/sync_http_client.dart';
import 'package:dmtools/src/js/sync_retry_policy.dart';
import 'package:test/test.dart';

import 'echo_server_helper.dart';

void main() {
  policyConfigTests();
  policyOverrideAndUrlTests();
  policyStatusAndBudgetTests();
  delayMathTests();
  jitterDelayTests();
  rateLimitResetWaitTests();
  rateLimitRetryAfterTests();
  deterministicRetryTests();
  retryIntegrationTests();
  successGateTests();
}

/// Java `RetryPolicyTest` additions from epam/dm.ai 3fa210e6 (#635):
/// retryability is judged by status code and body, never by substrings of
/// an error message (the message embeds the request URL, so an ephemeral
/// port like 50312 misfired the old "503" check and retried a 400).
void deterministicRetryTests() {
  group('SyncRetryPolicy deterministic retryability (dm.ai#635)', () {
    const policy = SyncRetryPolicy(
      maxAttempts: 5,
      baseDelayMs: 1000,
      maxDelayMs: 60000,
      backoffMultiplier: 2.0,
      jitterFactor: 0.0,
    );

    test('URL port digits are never read as a retryable status code', () {
      // Mirrors testRestClientExceptionUrlDigitsAreNotStatusCodes: the
      // failing message carries the request URL with an ephemeral port.
      for (final port in ['50312', '42950', '15020', '45043']) {
        final message = 'printAndCreateException error: '
            'http://127.0.0.1:$port/keyerror\nbad key\nBad Request\n400';
        expect(policy.shouldRetry(1, 400, message), isFalse,
            reason: 'port $port');
        expect(policy.isRetryableStatus(400, message), isFalse,
            reason: 'port $port');
      }
    });

    test('retryable by status code or rate-limit body', () {
      // Mirrors testRestClientExceptionRetryableByStatusOrBody.
      expect(policy.shouldRetry(1, 502), isTrue);
      expect(policy.shouldRetry(1, 504), isTrue);
      expect(policy.shouldRetry(1, 400, 'Too Many Requests'), isTrue);
      expect(policy.shouldRetry(1, 400, 'rate limit exceeded'), isTrue);
      expect(policy.shouldRetry(1, 404, 'nope'), isFalse);
      // Body matching is case-insensitive, like Java's toLowerCase.
      expect(policy.shouldRetry(1, 400, 'Request Was Throttled'), isTrue);
    });

    test(
        'successful 2xx/3xx responses are never retried, even with a '
        'rate-limit body', () {
      // Java only runs the body check on the exception path of failed
      // requests; a successful response never reaches it. A 200 whose body
      // merely mentions throttling (e.g. Jira issues *about* rate limits)
      // must not be re-issued with backoff.
      expect(policy.shouldRetry(1, 200, 'rate limit exceeded'), isFalse);
      expect(policy.shouldRetry(1, 302, 'throttled'), isFalse);
      expect(policy.shouldRetry(1, 204), isFalse);
    });
  });
}

String? _throttleOnEnv(String k) => switch (k) {
      'JIRA_WAIT_BEFORE_PERFORM' => 'true',
      'SLEEP_TIME_REQUEST' => '1500',
      _ => null,
    };

String? _throttleDefaultEnv(String k) =>
    k == 'JIRA_WAIT_BEFORE_PERFORM' ? 'true' : null;

String? _throttleOffEnv(String k) => switch (k) {
      'JIRA_WAIT_BEFORE_PERFORM' => 'false',
      'SLEEP_TIME_REQUEST' => '1500',
      _ => null,
    };

void policyConfigTests() {
  group('SyncRetryPolicy configuration', () {
    test('cloud policy matches RetryPolicyConfig.forJiraCloud', () {
      final policy = SyncRetryPolicy.forJiraCloud();
      expect(policy.maxAttempts, 7);
      expect(policy.baseDelayMs, 2000);
      expect(policy.maxDelayMs, 120000);
      expect(policy.backoffMultiplier, 2.0);
      expect(policy.jitterFactor, 0.4);
    });

    test('environment defaults match RetryPolicyConfig defaults', () {
      final policy = SyncRetryPolicy.fromEnvMap((_) => null);
      expect(policy.maxAttempts, 5);
      expect(policy.baseDelayMs, 1000);
      expect(policy.maxDelayMs, 60000);
      expect(policy.backoffMultiplier, 2.0);
      expect(policy.jitterFactor, 0.3);
      // Per-perform throttle defaults: off, 300ms when enabled (Java
      // BasicJiraClient defaults).
      expect(policy.waitBeforePerform, isFalse);
      expect(policy.sleepTimeRequestMs, 300);
      expect(policy.performDelayMs, 0);
    });

    test('JIRA_WAIT_BEFORE_PERFORM + SLEEP_TIME_REQUEST drive the throttle',
        () {
      final policy = SyncRetryPolicy.fromEnvMap(_throttleOnEnv);
      expect(policy.waitBeforePerform, isTrue);
      expect(policy.sleepTimeRequestMs, 1500);
      expect(policy.performDelayMs, 1500);
      final disabled = SyncRetryPolicy.fromEnvMap(_throttleDefaultEnv);
      expect(disabled.performDelayMs, 300); // SLEEP_TIME_REQUEST default
      final off = SyncRetryPolicy.fromEnvMap(_throttleOffEnv);
      expect(off.performDelayMs, 0);
    });
  });
}

/// Env overrides and per-URL policy selection.
void policyOverrideAndUrlTests() {
  group('SyncRetryPolicy configuration', () {
    test('environment overrides are honored', () {
      final env = {
        'JIRA_RETRY_MAX_ATTEMPTS': '3',
        'JIRA_RETRY_BASE_DELAY_MS': '50',
        'JIRA_RETRY_MAX_DELAY_MS': '500',
        'JIRA_RETRY_BACKOFF_MULTIPLIER': '3.0',
        'JIRA_RETRY_JITTER_FACTOR': '0.1',
      };
      final policy = SyncRetryPolicy.fromEnvMap((k) => env[k]);
      expect(policy.maxAttempts, 3);
      expect(policy.baseDelayMs, 50);
      expect(policy.maxDelayMs, 500);
      expect(policy.backoffMultiplier, 3.0);
      expect(policy.jitterFactor, 0.1);
    });

    test('JIRA_RETRY_ENABLED=false disables retrying', () {
      final policy = SyncRetryPolicy.fromEnvMap(
          (k) => k == 'JIRA_RETRY_ENABLED' ? 'false' : null);
      expect(policy.maxAttempts, 0);
      expect(policy.shouldRetry(1, 429), isFalse);
    });

    test('forUrl picks the cloud policy for atlassian.net', () {
      final policy =
          SyncRetryPolicy.forUrl('https://x.atlassian.net/rest/api/2/issue');
      expect(policy.maxAttempts, 7);
    });

    test('forUrl picks the cloud policy for JIRA_CLOUD=true', () {
      final policy = SyncRetryPolicy.forUrl(
        'http://jira.local/rest/api/2/issue',
        get: (k) => k == 'JIRA_CLOUD' ? 'true' : null,
      );
      expect(policy.maxAttempts, 7);
    });

    test('forUrl keeps the default policy elsewhere', () {
      final policy = SyncRetryPolicy.forUrl('http://127.0.0.1:1/x');
      expect(policy.maxAttempts, 5);
    });
  });
}

/// Retryable statuses and the Java attempt budget.
void policyStatusAndBudgetTests() {
  group('SyncRetryPolicy configuration', () {
    test('retryable statuses are 429 and the 502/503/504 family', () {
      final policy = SyncRetryPolicy.fromEnvMap((_) => null);
      for (final status in [429, 502, 503, 504]) {
        expect(policy.isRetryableStatus(status), isTrue, reason: '$status');
      }
      for (final status in [200, 400, 401, 404, 500]) {
        expect(policy.isRetryableStatus(status), isFalse, reason: '$status');
      }
    });

    test('attempt budget matches Java (retry while attempt < maxRetries)', () {
      const policy = SyncRetryPolicy(
        maxAttempts: 5,
        baseDelayMs: 1000,
        maxDelayMs: 60000,
        backoffMultiplier: 2.0,
        jitterFactor: 0.0,
      );
      expect(policy.shouldRetry(1, 429), isTrue);
      expect(policy.shouldRetry(4, 429), isTrue);
      expect(policy.shouldRetry(5, 429), isFalse);
      expect(policy.shouldRetry(1, 404), isFalse);
      expect(policy.shouldRetry(1, 0), isTrue); // connection error
    });
  });
}

void delayMathTests() {
  group('SyncRetryPolicy delay math', () {
    const policy = SyncRetryPolicy(
      maxAttempts: 5,
      baseDelayMs: 1000,
      maxDelayMs: 6000,
      backoffMultiplier: 2.0,
      jitterFactor: 0.0,
    );

    test('exponential backoff doubles per attempt', () {
      expect(policy.statusDelayMs(1), 1000);
      expect(policy.statusDelayMs(2), 2000);
      expect(policy.statusDelayMs(3), 4000);
    });

    test('delay caps at maxDelayMs', () {
      expect(policy.statusDelayMs(4), 6000);
      expect(policy.statusDelayMs(8), 6000);
    });

    test('Retry-After header overrides the backoff', () {
      expect(policy.statusDelayMs(1, {'Retry-After': '2'}), 2000);
      expect(policy.statusDelayMs(3, {'retry-after': '1'}), 1000);
      expect(policy.statusDelayMs(3, {'Retry-After': '0'}), 0);
    });

    test('Retry-After above 300s aborts (null)', () {
      expect(policy.statusDelayMs(1, {'Retry-After': '301'}), isNull);
    });

    test('X-RateLimit-Reset computes the wait from now (+1s, capped)', () {
      final now = DateTime.now();
      final reset = ((now.millisecondsSinceEpoch + 4000) / 1000).round();
      final delay = policy.statusDelayMs(1, {'X-RateLimit-Reset': '$reset'});
      expect(delay, greaterThan(0));
      expect(delay, lessThanOrEqualTo(6000));
    });

    test('connection-error schedule doubles from 200ms and caps at 5s', () {
      expect(policy.connectionDelayMs(1), 200);
      expect(policy.connectionDelayMs(2), 400);
      expect(policy.connectionDelayMs(3), 800);
      expect(policy.connectionDelayMs(10), 5000);
    });
  });
}

/// Jitter stays within ±jitterFactor/2 (deterministic Random(42)).
void jitterDelayTests() {
  group('SyncRetryPolicy delay math', () {
    test('jitter stays within ±jitterFactor/2 of the delay', () {
      final jittered = SyncRetryPolicy(
        maxAttempts: 8,
        baseDelayMs: 10000,
        maxDelayMs: 60000,
        backoffMultiplier: 2.0,
        jitterFactor: 0.4,
        random: Random(42),
      );
      // Attempts 1-2 sit under the cap: 10000/20000 ±20%.
      for (var attempt = 1; attempt <= 2; attempt++) {
        final nominal = 10000 * (1 << (attempt - 1));
        final delay = jittered.statusDelayMs(attempt)!;
        expect(delay, greaterThanOrEqualTo(nominal * 0.8));
        expect(delay, lessThanOrEqualTo(nominal * 1.2));
      }
      // Attempt 5 is capped at 60000 and still jitters ±20% around the cap.
      final capped = jittered.statusDelayMs(5)!;
      expect(capped, greaterThanOrEqualTo(48000));
      expect(capped, lessThanOrEqualTo(72000));
    });
  });
}

/// Default policy mirror of Java RetryPolicyTest's (maxDelayMs 60s, jitter
/// 0.3) for the rate-limit wait groups below.
final _rateLimitPolicy = SyncRetryPolicy.fromEnvMap((_) => null);

int _resetSecondsFromNow(int offsetSeconds) =>
    (DateTime.now().millisecondsSinceEpoch / 1000).round() + offsetSeconds;

/// Policy built with `RATE_LIMIT_MAX_WAIT_SECONDS` set to [value].
SyncRetryPolicy _policyWithRateLimitCap(String? value) =>
    SyncRetryPolicy.fromEnvMap(
        (k) => k == 'RATE_LIMIT_MAX_WAIT_SECONDS' ? value : null);

/// X-RateLimit-Reset parity with Java PR epam/dm.ai#624 (gh-318): the
/// reset wait is honored up to the configurable `RATE_LIMIT_MAX_WAIT_
/// SECONDS` cap (default 3600s) — never capped by `maxDelayMs`, never
/// aborted. Assertions are on the computed delay value; nothing sleeps.
void rateLimitResetWaitTests() {
  group('SyncRetryPolicy X-RateLimit-Reset wait (Java dm.ai#624 parity)', () {
    final policy = _rateLimitPolicy;

    test('long X-RateLimit-Reset wait is honored, not capped at maxDelayMs',
        () {
      final delay = policy.statusDelayMs(
          1, {'X-RateLimit-Reset': '${_resetSecondsFromNow(600)}'});
      // ~600s + 1s buffer; maxDelayMs is 60s and must not cap it.
      expect(delay, greaterThan(policy.maxDelayMs));
      expect(delay, inInclusiveRange(595000, 602000));
    });

    test('a small policy maxDelayMs cannot cap the reset wait either', () {
      const tiny = SyncRetryPolicy(
        maxAttempts: 5,
        baseDelayMs: 100,
        maxDelayMs: 1000,
        backoffMultiplier: 2.0,
        jitterFactor: 0.0,
      );
      final delay = tiny.statusDelayMs(
          1, {'X-RateLimit-Reset': '${_resetSecondsFromNow(600)}'});
      expect(delay, inInclusiveRange(595000, 602000));
    });

    test('X-RateLimit-Reset a few seconds out is honored', () {
      final delay = policy.statusDelayMs(
          1, {'X-RateLimit-Reset': '${_resetSecondsFromNow(5)}'});
      expect(delay, inInclusiveRange(5000, 7000)); // ~5s + 1s buffer
    });

    test('far-future reset is capped at the default 3600s cap, not thrown', () {
      final delay = policy.statusDelayMs(
          1, {'X-RateLimit-Reset': '${_resetSecondsFromNow(7200)}'});
      expect(delay, SyncRetryPolicy.defaultRateLimitMaxWaitSeconds * 1000);
    });

    test('RATE_LIMIT_MAX_WAIT_SECONDS is configurable', () {
      final capped = _policyWithRateLimitCap('300');
      expect(capped.rateLimitMaxWaitSeconds, 300);
      final delay = capped.statusDelayMs(
          1, {'X-RateLimit-Reset': '${_resetSecondsFromNow(3600)}'});
      expect(delay, 300000); // capped at the configured 300s, no jitter
    });

    test('invalid RATE_LIMIT_MAX_WAIT_SECONDS falls back to the default', () {
      for (final value in ['', 'abc', '0', '-5']) {
        final p = _policyWithRateLimitCap(value);
        expect(p.rateLimitMaxWaitSeconds, 3600, reason: "value '$value'");
      }
    });

    test('default rate-limit max wait is 3600 seconds', () {
      expect(SyncRetryPolicy.defaultRateLimitMaxWaitSeconds, 3600);
      expect(policy.rateLimitMaxWaitSeconds, 3600);
    });
  });
}

/// Retry-After parity with Java PR epam/dm.ai#624 (gh-318): a 429
/// rate-limit Retry-After is honored (up to the rate-limit cap) instead of
/// aborted; the 300s abort survives only for non-rate-limit responses.
void rateLimitRetryAfterTests() {
  group('SyncRetryPolicy 429 Retry-After (Java dm.ai#624 parity)', () {
    final policy = _rateLimitPolicy;

    test('429 Retry-After beyond 5 minutes is honored, not aborted', () {
      final delay = policy.statusDelayMs(1, const {'Retry-After': '600'}, 429);
      // Definitely beyond the old 300s abort threshold; ~600s within the
      // 0.3-jitter band (±15%).
      expect(delay, greaterThan(SyncRetryPolicy.maxRetryAfterSeconds * 1000));
      expect(delay, inInclusiveRange(510000, 690000));
    });

    test('429 Retry-After above the rate-limit cap is capped, not aborted', () {
      final delay = policy.statusDelayMs(1, const {'Retry-After': '7200'}, 429);
      final capMs = SyncRetryPolicy.defaultRateLimitMaxWaitSeconds * 1000;
      expect(delay,
          inInclusiveRange((capMs * 0.84).toInt(), (capMs * 1.16).toInt()));
    });

    test('non-429 Retry-After beyond 5 minutes still aborts', () {
      expect(
          policy.statusDelayMs(1, const {'Retry-After': '600'}, 503), isNull);
      expect(
        policy.statusDelayMs(1, const {'Retry-After': '390883'}, 503),
        isNull,
      );
    });

    test('missing status code keeps the 300s abort for Retry-After', () {
      // Legacy call shape (no statusCode): never treated as rate-limited.
      expect(policy.statusDelayMs(1, const {'Retry-After': '600'}), isNull);
    });
  });
}

void retryIntegrationTests() {
  group('SyncHttpClient retry wiring', () {
    late EchoServer server;

    setUpAll(() async {
      server = EchoServer();
      await server.start();
    });

    tearDownAll(() => server.stop());

    test('429 + Retry-After: 0 is retried and the echo answer is returned', () {
      final resp =
          SyncHttpClient.get('http://127.0.0.1:${server.port}/dt-retry/a');
      expect(resp.statusCode, 200);
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      expect(body['path'], '/dt-retry/a');
    });

    test('503 without retry headers is retried with backoff', () {
      final stopwatch = Stopwatch()..start();
      final resp =
          SyncHttpClient.get('http://127.0.0.1:${server.port}/dt-retryfail/b');
      stopwatch.stop();
      expect(resp.statusCode, 200);
      // First attempt pays the 1s base backoff before the retry. The
      // jittered delay ranges 850–1150 ms (±jitterFactor/2), so the
      // assertion uses the true minimum minus a small stopwatch tolerance
      // instead of a value inside the jitter band (flake-proof).
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(800));
    });

    test('persistent 429 exhausts the attempt budget and surfaces 429', () {
      final resp = SyncHttpClient.get(
          'http://127.0.0.1:${server.port}/dt-retryalways/c');
      expect(resp.statusCode, 429);
      // Header names are case-insensitive: the bridge transport lowercases
      // them (dart:io), the curl transport preserves the server's casing.
      final retryAfter = resp.headers.entries
          .firstWhere((e) => e.key.toLowerCase() == 'retry-after')
          .value;
      expect(retryAfter, '0');
    });
  });
}

/// gh-356 review (dm.ai#635 port): the response-body check must never
/// fire for a successful 2xx/3xx — Java only runs it on the exception
/// path of a failed request.
void successGateTests() {
  group('SyncHttpClient success-response gate', () {
    late EchoServer server;

    setUpAll(() async {
      server = EchoServer();
      await server.start();
    });

    tearDownAll(() => server.stop());

    test('a 200 whose body mentions rate limiting is not retried', () {
      final resp = SyncHttpClient.get(
          'http://127.0.0.1:${server.port}/dt-200ratelimit/a');
      expect(resp.statusCode, 200);
      final hits = jsonDecode(
          SyncHttpClient.get('http://127.0.0.1:${server.port}/__retry_hits')
              .body) as Map<String, dynamic>;
      expect(hits['/dt-200ratelimit/a'], 1);
    });
  });
}
