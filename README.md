# dmtools-dart

![tests](.badges/tests.svg)
![coverage](.badges/coverage.svg)
![crap4dart](.badges/crap4dart.svg)
![memory](.badges/memory.svg)

Pure Dart port of [DMTools](https://github.com/epam/dm.ai) — the enterprise
dark-factory orchestrator (Jira, ADO, GitHub, GitLab, Confluence, TestRail,
Bitrise, Jenkins, Figma, Teams, SharePoint, AI providers) with a QuickJS
scripting runtime via `dart:ffi`. No JVM, no GraalVM — Dart only.

- **[GOAL.md](GOAL.md)** — the spec: mission, constraints, phases 0–5
- **[AGENTS.md](AGENTS.md)** — the operating manual: rules, commands, layout
- **[test/integration/README.md](test/integration/README.md)** — the four test layers and the live-integration credential matrix

## Quick start

### Install the prebuilt binary (no Dart SDK required)

```bash
curl -fsSL \
  "https://github.com/epam/dmtools-dart/releases/latest/download/install.sh" | sh
```

The repository is public — no token required. (`DMTOOLS_GITHUB_TOKEN` is
still honored as an optional override for API rate limits or private forks.)

This installs a standalone AOT binary plus the QuickJS shared library it
loads to `~/.dmtools/bin` and puts it on your `PATH`. Install a specific
version with `... | sh -s -- v0.1.0` (or `DMTOOLS_VERSION=v0.1.0`).
Prebuilt platforms: `linux-x64`, `macos-x64`, `macos-arm64`,
`windows-x64` (zip). Releases are cut dm.ai-style by pressing
the **Run workflow** button in
[release-cli.yml](.github/workflows/release-cli.yml) — the patch version
auto-increments from `pubspec.yaml` (or set a custom version), the bump
is committed and tagged, assets and `dmtools-checksums.sha256` are
published, and installs are exercised on every supported OS by
[install-test.yml](.github/workflows/install-test.yml).

### Install on Windows

Three entry points, exactly the dm.ai shape:

```bat
REM cmd.exe / curl — bootstraps the PowerShell installer
curl -fsSL https://raw.githubusercontent.com/epam/dmtools-dart/main/install.bat -o "%TEMP%\dmtools-install.bat" && "%TEMP%\dmtools-install.bat"
```

```powershell
# PowerShell one-liner
irm https://github.com/epam/dmtools-dart/releases/latest/download/install.ps1 | iex
```

```bash
# Git Bash — the same install.sh as on Linux/macOS
curl -fsSL https://raw.githubusercontent.com/epam/dmtools-dart/main/install.sh | bash
```

All three install to `%USERPROFILE%\.dmtools\bin` (`dmtools.exe`, the
QuickJS library under `native\quickjs\`, and a `dmtools.cmd` launcher
pinning `JSR_QUICKJS_LIB`) and append the bin dir to the user `PATH`.
The `install.sh` path additionally writes a bash launcher for Git Bash
sessions and appends to `~/.bashrc`.

### Install from a source checkout (macOS / Linux)

```bash
make install          # build + install to ~/.local/bin (override: PREFIX=…)
```

Installs a small `dmtools` launcher plus the AOT binary (`dmtools.bin`) to
`$(PREFIX)/bin`, with the QuickJS shared library in `native/quickjs/` beside
them. The launcher exports `JSR_QUICKJS_LIB` with the absolute library path —
required because the runtime's exe-relative fallback (`Platform.script`)
does not resolve to the installed executable in AOT builds — so `dmtools`
works from any directory. `install.sh` uses the same launcher layout and
additionally strips macOS quarantine and ad-hoc re-signs the binary
(fa1.dev installer pattern). Prints a PATH hint when `~/.local/bin` is not
on your `PATH` (macOS: add `export PATH="$HOME/.local/bin:$PATH"` to
`~/.zshrc`). macOS/Linux only — Windows users: install.ps1/install.bat or the zip bundle (above);
with `make build`.

### Build from source

```bash
dart pub get
make native          # compile the QuickJS shared library (required before tests)
dart format .
dart analyze
dart test
```

> **`make native` is required once per checkout.** The JS runtime
> (`quickjs_runtime` package) loads `libquickjs_bridge.so` at test and CLI
> run time; without it you get raw `dlopen ... libquickjs_bridge.so (no
> such file)` failures. `make native` builds it inside the package
> checkout (override the location via `JSR_QUICKJS_LIB`); see the
> [Makefile](Makefile) for platform notes. CI builds it automatically.

Quality gates (CI [quality.yml](.github/workflows/quality.yml)): `dart format`
clean, `dart analyze` clean, 80% line coverage on `lib`, and a CRAP score
≤ 8.0 enforced by [crap4dart](crap4dart.yaml). Live integration tests run
nightly and on demand — never per-PR — via
[integration.yml](.github/workflows/integration.yml); each integration runs in
its own matrix slot with its own concurrency group.

Repo automation (dm.ai parity): the
[agents/](agents) submodule pins [IstiN/dmtools-agents](https://github.com/IstiN/dmtools-agents)
and feeds the L4 suite; [machine-sm.yml](.github/workflows/machine-sm.yml)
reconciles the loop every 10 min (silent branch refresh + dispatch-only CI:
pushes fire no workflows, the SM validates heads via `workflow_dispatch`);
[merge-trigger.yml](.github/workflows/merge-trigger.yml)
squash-merges `pr_approved` issues once CI is green (gated by the
`MERGE_TRIGGER_ENABLED` repo variable);
[ai-teammate.yml](.github/workflows/ai-teammate.yml)
runs the AI Teammate legs on issue events and on machine-sm.yml dispatches.

## Configuration

Every integration is configured through environment variables resolved in a
fixed chain: overrides → `config.properties` → `dmtools.env` → OS env vars. A
config that works with Java DMTools works unchanged here. Check what is wired
up with:

```bash
dart run bin/dmtools.dart doctor    # configuration presence report
```

The full per-integration variable matrix (auth secrets plus sandbox-target
`DMTOOLS_IT_*` variables) lives in
[test/integration/README.md](test/integration/README.md).

## Tracker routing

Ticket tools live behind a tracker-agnostic surface: the core ticket tools of
every integration (Jira, ADO Boards, GitHub Issues) carry unified `tracker_*`
aliases (`tracker_get_ticket`, `tracker_search`, `tracker_post_comment`, … —
`tracker_move_to_status` is jira/github only), and
`DEFAULT_TRACKER` (jira | ado | github) picks the carrier an alias resolves to —
one variable re-routes agent scripts, job configs, and CLI calls onto any
tracker. GitHub Issues is a full backend with no Jira config at all: `gh-<n>`
ticket keys route through the JS bridge to the tracker repo
(`DMTOOLS_TRACKER_REPO`, else `GITHUB_REPOSITORY`, else
`SOURCE_GITHUB_REPOSITORY`). The SCM side mirrors it:
`source_code_*` aliases (`DEFAULT_SOURCE_CODE`) and the `scm.provider` config in
agent scripts. The abstraction contract is specified in
[GOAL.md](GOAL.md) ("Core abstractions").

```bash
DEFAULT_TRACKER=github dmtools tracker_get_ticket --data '{"key": "epam/dmtools-dart#38"}'
```

Alias calls dispatch the resolved carrier tool with its real credentials —
this one needs `SOURCE_GITHUB_TOKEN` (public repos included).

## Machine loop (AI teammates)

GitHub issues drive the loop end to end: label an issue and AI teammates
develop it, review the PR, rework findings, and merge — zero human steps.
Full map: [docs/ai_factory.md](docs/ai_factory.md); replicate on another repo:
[docs/factory_setup.md](docs/factory_setup.md).

| Label | Leg |
|---|---|
| `agent:dev` | dev run — agent reads the issue, pushes a branch, opens an `ai/gh-<n>` PR "Closes #<n>" (`bug` label / `[BUG]` title routes to the bug teammate) |
| `agent:review` | review run — formal APPROVE / REQUEST_CHANGES verdict on the linked PR |
| `agent:rework` | rework run — fixes blocking review threads, pushes to the same branch |
| `needs-human` | escalation after `MAX_AUTO_REWORK_ROUNDS` (default 2) rework rounds without an APPROVE |

APPROVE + green CI → `pr_approved` →
[merge-trigger.yml](.github/workflows/merge-trigger.yml) squash-merges and
closes the issue. Labels the machine adds with `GITHUB_TOKEN` do not fire
`labeled` events, so the
[machine-sm.yml](.github/workflows/machine-sm.yml) cron (every 10 minutes) is
the safety net: the SM rule engine reads the loop state and re-fires the
stalled leg — rework on red CI, review on green, merge for approved PRs.
`agent:skip` on an issue is the hard opt-out. Probe the reconciler without
acting:

```bash
gh workflow run machine-sm.yml -f dryRun=true
```

The same tick locally — the pre-flight dry run before enabling the rules on a
repo (`--live` to act): `./scripts/machine_tick.sh`.

Runner configs (provider/model pinning per leg) live in
[.dmtools/runners/](.dmtools/runners/), selected per leg by the factory guard
via [.dmtools/config.js](.dmtools/config.js).

### Runner boot contract

The fa provider wrapper
([agents/scripts/providers/fa.sh](agents/scripts/providers/fa.sh)) refuses to
boot unless the runner declares its provider up front — `FA_PROVIDERS_QUEUE`
alone is NOT a boot source (the wrapper never reads it as one):

- `AI_AGENT_PROVIDER=fa` — selects the fa provider wrapper.
- `FA_PROVIDER_TYPE` — catalog provider kind (`anthropic`,
  `openai-completions`, `zai`, `kimi`, …).
- `FA_PROVIDER_CONFIG` — JSON with mandatory `baseUrl`, `model`,
  `apiKeyEnvVar` keys (fa never guesses catalog defaults):

  ```json
  {
    "FA_PROVIDER_TYPE": "zai",
    "FA_PROVIDER_CONFIG":
      "{\"baseUrl\":\"https://api.z.ai/api/coding/paas/v4\",\"model\":\"glm-5.3-flash\",\"apiKeyEnvVar\":\"ZAI_CODE_KEY\"}"
  }
  ```

A runner missing either fa variable dies before fa starts: the leg writes no
mandatory outputs and the SM ping-pongs review ↔ rework forever. The contract
is enforced by the `faProviderPreconfigTests` pins in
[test/machine_kit/runner_wiring_test.dart](test/machine_kit/runner_wiring_test.dart).
