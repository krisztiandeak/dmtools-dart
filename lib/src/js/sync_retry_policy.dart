/// Rate-limit / transient-failure retry policy for the sync HTTP transport
/// (gh-191, P6-JSY-18).
///
/// Dart port of the Java `RetryPolicy` + `RetryPolicyConfig`
/// (`dmtools-core/.../networking/`), wired into `JiraClient.execute`:
/// exponential backoff with jitter, `Retry-After` and `X-RateLimit-Reset`
/// header honoring, and a connection-error schedule for transport failures.
///
/// Configuration (Java `RetryPolicyConfig` parity):
/// - Cloud instances (`JIRA_CLOUD=true` or an `atlassian.net` URL) get the
///   Cloud-tuned policy: 7 attempts, 2s base delay, 120s cap, 2.0 backoff,
///   0.4 jitter.
/// - Everything else reads the `JIRA_RETRY_*` environment: `MAX_ATTEMPTS`
///   (5), `BASE_DELAY_MS` (1000), `MAX_DELAY_MS` (60000),
///   `BACKOFF_MULTIPLIER` (2.0), `JITTER_FACTOR` (0.3), `ENABLED` (true).
/// - Rate-limit waits (Java PR epam/dm.ai#624, gh-318): `X-RateLimit-Reset`
///   and 429 `Retry-After` are honored up to the configurable
///   `RATE_LIMIT_MAX_WAIT_SECONDS` cap (default 3600s) — never capped by
///   `MAX_DELAY_MS`, never aborted; the 300s `Retry-After` abort applies
///   only to non-rate-limit responses.
/// - The per-perform throttle (Java `BasicJiraClient`): `JIRA_WAIT_BEFORE_
///   PERFORM` (bool, default false) sleeps `SLEEP_TIME_REQUEST`
///   milliseconds (default 300) before each request execution.
library;

import 'dart:io' show Platform;
import 'dart:math';

import '../config/property_reader.dart';

/// Immutable retry policy; all delay math is pure and testable.
class SyncRetryPolicy {
  /// Total attempt budget, mirroring Java `maxRetries` (the loop runs while
  /// `attemptNumber <= maxRetries`, so 0 disables retrying entirely).
  final int maxAttempts;

  /// First backoff delay in milliseconds.
  final int baseDelayMs;

  /// Delay cap in milliseconds.
  final int maxDelayMs;

  /// Exponential multiplier applied per attempt.
  final double backoffMultiplier;

  /// Jitter factor: the delay moves by up to `jitterFactor / 2` in either
  /// direction (Java `addJitter`).
  final double jitterFactor;

  /// Random source for jitter (injected in tests).
  final Random random;

  /// Java `isWaitBeforePerform`: throttle every perform (env
  /// `JIRA_WAIT_BEFORE_PERFORM`, default false).
  final bool waitBeforePerform;

  /// Java `sleepTimeRequest`: the throttle length in milliseconds (env
  /// `SLEEP_TIME_REQUEST`, default 300).
  final int sleepTimeRequestMs;

  /// Java `rateLimitMaxWaitSeconds`: cap for server-mandated rate-limit
  /// waits (`X-RateLimit-Reset`, or a 429 `Retry-After`) — env/property
  /// `RATE_LIMIT_MAX_WAIT_SECONDS`, default
  /// [defaultRateLimitMaxWaitSeconds]. Never capped by [maxDelayMs] and
  /// never aborted.
  final int rateLimitMaxWaitSeconds;

  /// Java `MAX_RETRY_AFTER_SECONDS`: abort threshold for a non-rate-limit
  /// `Retry-After` wait (5 minutes).
  static const int maxRetryAfterSeconds = 300;

  /// Java `DEFAULT_RATE_LIMIT_MAX_WAIT_SECONDS`: default cap for a genuine
  /// rate-limit wait (60 minutes — GitHub resets up to ~hourly).
  static const int defaultRateLimitMaxWaitSeconds = 3600;

  /// Seconds → milliseconds conversion used by the server-header math.
  static const int _msPerSecond = 1000;

  /// Creates a policy with explicit settings.
  const SyncRetryPolicy({
    required this.maxAttempts,
    required this.baseDelayMs,
    required this.maxDelayMs,
    required this.backoffMultiplier,
    required this.jitterFactor,
    this.random = const _NeutralRandom(),
    this.waitBeforePerform = false,
    this.sleepTimeRequestMs = 300,
    this.rateLimitMaxWaitSeconds = defaultRateLimitMaxWaitSeconds,
  });

  /// Milliseconds to sleep before each request execution (Java
  /// `AbstractRestClient` pre-loop throttle); `0` disables the throttle.
  int get performDelayMs => waitBeforePerform ? sleepTimeRequestMs : 0;

  /// Java `RetryPolicyConfig.forJiraCloud`: Atlassian-recommended Cloud
  /// tuning — more attempts, longer cap, wider jitter.
  factory SyncRetryPolicy.forJiraCloud([Random? random]) => SyncRetryPolicy(
        maxAttempts: 7,
        baseDelayMs: 2000,
        maxDelayMs: 120000,
        backoffMultiplier: 2.0,
        jitterFactor: 0.4,
        random: random ?? Random(),
      );

  /// Java `RetryPolicyConfig.fromEnvironment`; [get] resolves `JIRA_RETRY_*`
  /// values (defaults to [PropertyReader.getOverrides], then
  /// [PropertyReader.testEnvironment] under [PropertyReader.testIsolation],
  /// then [Platform.environment]).
  factory SyncRetryPolicy.fromEnvironment(
          [String? Function(String key)? get, Random? random]) =>
      SyncRetryPolicy.fromEnvMap(
        (key) => get?.call(key) ?? _defaultLookup(key),
        random,
      );

  static String? _defaultLookup(String key) {
    final overrides = PropertyReader.getOverrides();
    if (overrides.containsKey(key)) return overrides[key];
    if (PropertyReader.testIsolation) {
      return PropertyReader.testEnvironment[key];
    }
    return Platform.environment[key];
  }

  /// Java `RetryPolicyConfig` semantics over an explicit key/value lookup.
  factory SyncRetryPolicy.fromEnvMap(String? Function(String) get,
          [Random? random]) =>
      (get('JIRA_RETRY_ENABLED')?.toLowerCase() == 'false')
          ? const SyncRetryPolicy(
              maxAttempts: 0,
              baseDelayMs: 0,
              maxDelayMs: 0,
              backoffMultiplier: 1.0,
              jitterFactor: 0.0,
            )
          : SyncRetryPolicy(
              maxAttempts: _intEnv(get, 'JIRA_RETRY_MAX_ATTEMPTS', 5),
              baseDelayMs: _intEnv(get, 'JIRA_RETRY_BASE_DELAY_MS', 1000),
              maxDelayMs: _intEnv(get, 'JIRA_RETRY_MAX_DELAY_MS', 60000),
              backoffMultiplier:
                  _doubleEnv(get, 'JIRA_RETRY_BACKOFF_MULTIPLIER', 2.0),
              jitterFactor: _doubleEnv(get, 'JIRA_RETRY_JITTER_FACTOR', 0.3),
              waitBeforePerform:
                  get('JIRA_WAIT_BEFORE_PERFORM')?.toLowerCase() == 'true',
              sleepTimeRequestMs: _intEnv(get, 'SLEEP_TIME_REQUEST', 300),
              rateLimitMaxWaitSeconds: _rateLimitMaxWaitSeconds(get),
              random: random ?? Random(),
            );

  /// Java `JiraClient` constructor logic: `JIRA_CLOUD=true` or an
  /// `atlassian.net` base path selects the Cloud policy, everything else
  /// the environment/default policy.
  factory SyncRetryPolicy.forUrl(
    String url, {
    String? Function(String key)? get,
    Random? random,
  }) {
    final cloud = get?.call('JIRA_CLOUD')?.toLowerCase() == 'true' ||
        url.contains('atlassian.net');
    return cloud
        ? SyncRetryPolicy.forJiraCloud(random)
        : SyncRetryPolicy.fromEnvironment(get, random);
  }

  /// Whether [status] is retryable — Java `RetryPolicy.isRetryableStatus`
  /// (dm.ai#635): 429 and the 502/503/504 gateway family, or a response
  /// [body] that reads as a rate-limit/throttle signal ("rate limit",
  /// "too many requests", "throttl", case-insensitive). The decision is
  /// driven by the numeric status and the body only — never by substrings
  /// of an error message: the message embeds the request URL (host:port,
  /// ids), so an ephemeral port like 50312 misfired the old "503"
  /// substring check and retried a 400 five times.
  bool isRetryableStatus(int status, [String? body]) {
    if (status == 429 || status == 502 || status == 503 || status == 504) {
      return true;
    }
    final lower = (body ?? '').toLowerCase();
    return lower.contains('rate limit') ||
        lower.contains('too many requests') ||
        lower.contains('throttl');
  }

  /// Whether another attempt may be made after [attempt] (1-based) failed:
  /// Java retries while `attemptNumber < maxRetries`.
  bool canRetryAfter(int attempt) => attempt < maxAttempts;

  /// Whether a failed request at 1-based [attempt] with [statusCode]
  /// (`0` = transport failure) and response [body] should be retried.
  /// Successful 2xx/3xx responses are never retried — Java only runs the
  /// body check on the exception path of failed requests.
  bool shouldRetry(int attempt, int statusCode, [String? body]) {
    if (!canRetryAfter(attempt)) return false;
    if (statusCode == 0) return true;
    if (statusCode >= 200 && statusCode < 400) return false;
    return isRetryableStatus(statusCode, body);
  }

  /// Delay before the next attempt after a retryable-status [attempt]
  /// (1-based): server `Retry-After` / `X-RateLimit-Reset` headers from
  /// [headers] first, then exponential backoff with jitter. [statusCode]
  /// (the failing response's code) marks a genuine rate limit: its
  /// `Retry-After` may exceed [maxRetryAfterSeconds] and is honored up to
  /// [rateLimitMaxWaitSeconds] instead (Java PR epam/dm.ai#624). Returns
  /// `null` when a non-rate-limit `Retry-After` above [maxRetryAfterSeconds]
  /// demands an abort (Java throws IOException).
  int? statusDelayMs(int attempt,
      [Map<String, String> headers = const {}, int statusCode = 0]) {
    final server = _serverDelayMs(headers, DateTime.now(), statusCode);
    if (server == null) return null; // Retry-After over the cap: abort
    if (server.present) {
      return server.jittered ? _addJitter(server.ms) : server.ms;
    }
    return _addJitter(
      min(
        maxDelayMs,
        (baseDelayMs * pow(backoffMultiplier, attempt - 1)).toInt(),
      ),
    );
  }

  /// Java's connection-error schedule: `200 * 2^(attempt-1)` capped at 5s,
  /// no jitter.
  int connectionDelayMs(int attempt) =>
      min(5000, 200 * pow(2, attempt - 1).toInt());

  /// Server-mandated delay (Java `calculateDelayMs` header branches):
  /// `null` aborts (non-rate-limit `Retry-After` above
  /// [maxRetryAfterSeconds]); otherwise the milliseconds to wait plus
  /// whether the Java branch applies jitter to it (`Retry-After` does,
  /// `X-RateLimit-Reset` does not). `(ms: 0, jittered: false, present: false)`
  /// = no server header applies — fall through to exponential backoff.
  _ServerDelay? _serverDelayMs(
      Map<String, String> headers, DateTime now, int statusCode) {
    final retryAfter = _header(headers, 'retry-after');
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter);
      if (seconds != null) return _retryAfterDelayMs(seconds, statusCode);
    }
    final reset = _header(headers, 'x-ratelimit-reset');
    if (reset != null) {
      final resetMs = int.tryParse(reset);
      if (resetMs != null) {
        final delay = resetMs * _msPerSecond - now.millisecondsSinceEpoch;
        if (delay > 0) {
          // Honor the server's reset time (GitHub resets up to ~60 min
          // out): +1s buffer capped at the configurable rate-limit cap —
          // never by [maxDelayMs], never aborted, no jitter (Java parity).
          return (
            ms: min(
                delay + _msPerSecond, rateLimitMaxWaitSeconds * _msPerSecond),
            jittered: false,
            present: true,
          );
        }
      }
    }
    return const (ms: 0, jittered: false, present: false);
  }

  /// Java `Retry-After` branch: aborts (`null`) when a non-429 wait exceeds
  /// [maxRetryAfterSeconds]; a 429 rate limit is honored up to
  /// [rateLimitMaxWaitSeconds] instead — capped, never aborted.
  _ServerDelay? _retryAfterDelayMs(int seconds, int statusCode) {
    final rateLimited = statusCode == 429;
    if (!rateLimited && seconds > maxRetryAfterSeconds) return null; // abort
    var ms = seconds * _msPerSecond;
    if (rateLimited) ms = min(ms, rateLimitMaxWaitSeconds * _msPerSecond);
    return (ms: ms, jittered: true, present: true);
  }

  /// Case-insensitive [name] lookup over [headers].
  static String? _header(Map<String, String> headers, String name) {
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == name) return e.value;
    }
    return null;
  }

  /// Java `addJitter`: shift by up to `jitterFactor / 2` of the delay.
  int _addJitter(int delay) {
    if (jitterFactor == 0 || delay == 0) return delay;
    final jitter = delay * jitterFactor * (random.nextDouble() - 0.5);
    return max(0, delay + jitter.toInt());
  }

  static int _intEnv(String? Function(String) get, String key, int fallback) =>
      int.tryParse(get(key) ?? '') ?? fallback;

  /// Java `resolveRateLimitMaxWaitSeconds`: parses
  /// `RATE_LIMIT_MAX_WAIT_SECONDS`, falling back to
  /// [defaultRateLimitMaxWaitSeconds] when unset, unparsable, or `<= 0`.
  static int _rateLimitMaxWaitSeconds(String? Function(String) get) {
    final value = (get('RATE_LIMIT_MAX_WAIT_SECONDS') ?? '').trim();
    final parsed = int.tryParse(value);
    return (parsed != null && parsed > 0)
        ? parsed
        : defaultRateLimitMaxWaitSeconds;
  }

  static double _doubleEnv(
          String? Function(String) get, String key, double fallback) =>
      double.tryParse(get(key) ?? '') ?? fallback;
}

/// Server-mandated delay outcome: the milliseconds to wait plus whether
/// Java jitters that branch (`Retry-After` is jittered, `X-RateLimit-Reset`
/// is returned verbatim).
typedef _ServerDelay = ({int ms, bool jittered, bool present});

/// Jitter-neutral [Random] used as the const default (always returns the
/// 0.5 midpoint so `addJitter` is a no-op); the factories override it with
/// a live `Random()`.
class _NeutralRandom implements Random {
  const _NeutralRandom();

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0.5;

  @override
  int nextInt(int max) => 0;
}
