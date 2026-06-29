# Plan / Roadmap — filen-dart

What's known to be unimplemented, broken, or worth porting from the
Python sibling ([`filen-python`](../filen-python)). The terminal
goal is to mirror what was done for
[`internxt-dart`](../internxt-dart) — a tested, sharable library
that cloud-dart consumes instead of embedding its own copy.

**Playbook**: read these in `../internxt-dart/` before starting:
- `PLAN.md` — phase structure, status conventions, follow-on patterns
- `HISTORY.md` — the actual sequence the Internxt arc took (Phase 4 → 9.8)
- `LEARNINGS.md` — gotchas + lessons from the Internxt audit
- `AUDIT_6B.md` — the cloud-dart consumer audit + rewire blueprint

## Update (2026-05-30)

Most of this roadmap has landed. Done: file dedupe (Phase 0), de-Flutter
(Phase 1 — the core library is pure Dart), the module split + `lib/`
restructure (Phases 3, 6), and CI (Phase 8). The test build-out (Phase 4)
and a first pass of the feature-parity/test-quality work (Phase 5) are done
as of today: the suite was brought to the internxt-dart thoroughness bar
(**107 → 217 unit tests**, plus green live smoke + WebDAV live runs against a
real account), with several real bugs fixed along the way — see `HISTORY.md`
(2026-05-30) and `LEARNINGS.md`.

Still open: deeper feature-parity sweep vs `filen-python` (more of Phase 5),
the cloud-dart rewire (Phase 7), and porting the WebCrypto + CORS work
(preserved on the `wip-filen-webcrypto` branch) into the new `lib/` layout.
The snapshot below is the **original** pre-audit state, kept for context.

## Status snapshot (initial state, captured pre-audit)

**Repo state:**
- 8 git commits, no `lib/` directory, no `test/` directory.
- Two competing root files: `filen.dart` (v0.0.4, 4286 LOC, current
  intent) and `filen_1.dart` (v0.0.3, older copy, **stale**).
- `webdav_filesystem.dart` (23K) at root — InternxtFile/Directory
  analogs for shelf-dav.
- `pubspec.yaml`: name=`filen_dart`, version=`0.0.2`, `publish_to:
  none`, **does NOT declare flutter** as a dep.
- Cloud-dart embeds its own copy at
  `~/code/cloud-dart/lib/services/filen.dart` (4497 LOC, drifted
  from filen-dart's 4286 — same shape as Internxt's
  pre-Phase-6.c situation).

**The Flutter problem (PHASE 1 BLOCKER):**

`filen.dart` imports `package:flutter/foundation.dart` (for `kIsWeb`)
and `package:universal_html/html.dart` (for Web SubtleCrypto). Neither
is declared in pubspec.yaml — so `dart pub get` resolves but
`dart analyze` fails. The Flutter-specific Web-Crypto code paths
(file lines ~3908–3970) exist because pointycastle's AES-GCM is too
slow in dart2js; SubtleCrypto is the workaround. **Phase 1 must
either remove these branches (CLI doesn't need Web) or split them
behind a conditional import so the core library is pure-Dart.**

**Done:** nothing.

**Open — load-bearing (the whole arc):**

Each phase below is sized to fit a single focused session. Phases
have **dependencies** (Phase N requires Phase N-1) so a fresh
agent should execute them in order. Acceptance criteria are
explicit — don't move on until the previous phase passes.

---

## Phase 0 — file dedupe (~30 min)

**Goal:** one canonical filen.dart at root. Drop the stale copy.

**Steps:**
1. Verify `filen.dart` is v0.0.4 and `filen_1.dart` is v0.0.3 by
   reading the file headers (`/// FILEN CLI (v0.0.X)` comment).
2. Verify cloud-dart's `~/code/cloud-dart/lib/services/filen.dart`
   matches the v0.0.4 shape (same imports, especially Flutter +
   universal_html). It does as of this PLAN's writing.
3. `git rm filen_1.dart` and commit.

**Acceptance:**
- Only `filen.dart`, `webdav_filesystem.dart`, `pubspec.yaml`,
  `pubspec.lock`, `LICENSE`, `README.md` at root (plus `.git`,
  `.gitignore`, `.dart_tool`).
- `dart pub get` succeeds (it should — current state already does).

---

## Phase 1 — de-Flutter (~1 hour)

**Goal:** remove `package:flutter/foundation.dart` and
`package:universal_html/html.dart` from `filen.dart` so the
package is pure-Dart and doesn't carry hidden Flutter deps.

**Approach options:**

(a) **Drop the Web branches entirely.** The CLI doesn't run in a
    browser. All `if (kIsWeb) { ... html.window.crypto ... }` blocks
    can be removed; the `else` branch (pointycastle) is the only
    path that runs from a CLI. Cloud-dart's filen integration is
    where Web matters — but cloud-dart can subclass / wrap the
    library to add its own Web branches (mirrors how cloud-dart's
    Internxt adapter handles `kIsWeb` URL routing).

(b) **Conditional imports.** Keep `kIsWeb` as a runtime branch but
    swap the `package:flutter/foundation.dart` import for a small
    file-local helper (e.g. `const kIsWeb = identical(0, 0.0);` —
    the canonical pure-Dart kIsWeb detection) and the universal_html
    import for a conditional-import stub. More complex.

**Recommended: (a).** Cleaner, smaller surface. Cloud-dart's existing
embedded copy already proves the Web path works; that lives in
cloud-dart, not in this library.

**Steps:**
1. Audit all `kIsWeb` and `html.window.*` callsites in `filen.dart`.
   Should be ~3 functions (encrypt/decrypt/keygen) with `if (kIsWeb)`
   branches around lines 3908, 3937, 3967.
2. Delete the `if (kIsWeb)` branches; keep the pointycastle branch
   as the sole path.
3. Remove the imports `package:flutter/foundation.dart` and
   `package:universal_html/html.dart` from `filen.dart`.
4. `dart analyze` should be clean (no `unused_import` warnings,
   no missing-package errors).

**Acceptance:**
- `grep -E "package:flutter|universal_html|kIsWeb|html\." filen.dart`
  returns nothing.
- `dart analyze` runs without errors.
- A round-trip encrypt+decrypt smoke test still works — write a
  scratch `tool/probe_crypto.dart` if needed.

**Note for cloud-dart:** their Phase 7 rewire (analogous to
internxt's Phase 6.c) will need to add a Web wrapper. Document this
gotcha in cloud-dart's adapter file when you get to Phase 7.b below.

---

## Phase 2 — audit (~2 hours)

**Goal:** mirror internxt-dart's Phase 1–3 audit. Find dead code,
lying-contract bugs, dynamic-dispatch hazards, dependency lockstep
issues. Produce a `LEARNINGS.md` capturing what surfaces.

**Steps:**
1. Add stricter `analysis_options.yaml`:
   ```yaml
   include: package:lints/recommended.yaml
   analyzer:
     language:
       strict-casts: true
     errors:
       unused_import: error
       override_on_non_overriding_member: error
   ```
2. Run `dart analyze --fatal-infos` and triage the output.
3. Look specifically for:
   - **Dead `_underscore`-prefixed methods** (the Internxt audit
     found 9 of these).
   - **`@override` annotations on non-overriding members** (the
     `webdav_filesystem.dart` lying-contract bug shape — Internxt
     had 9 of these).
   - **Mutable shared state** that should be instance-bound vs.
     accidentally global.
4. Run a manual sweep for:
   - Unused public methods (cross-reference against cli.dart's
     dispatch table + WebDAV PROPPATCH/PROPFIND handlers).
   - Cache invalidation gaps (any mutating op that doesn't clear
     the parent listing — see internxt-dart's Phase 9.6 for the
     bug shape).
5. Write `LEARNINGS.md` documenting findings (mirror
   `../internxt-dart/LEARNINGS.md`'s structure).

**Acceptance:**
- `dart analyze` passes with `strict-casts: true`.
- `LEARNINGS.md` exists with at least 3 sections (audit findings,
  trust roots, dependency notes).
- Any genuine bugs found are tracked as commits in this phase, not
  carried into Phase 3.

---

## Phase 3 — module split (~3 hours)

**Goal:** split the ~4300-line monolith into focused root modules.
Mirror internxt-dart's Phase 4 layout exactly so a future Option C
(`cloud-cli` umbrella tool) can treat both libraries symmetrically.

**Target layout** (modules at the root, lib/ restructure comes in
Phase 6 — keep the disruption staged):

| Module | Owns | Approx LOC |
|---|---|---|
| `crypto.dart` | PBKDF2, AES-GCM, key derivation, RSA ops, the trust roots | 200 |
| `config.dart` | ConfigService — credentials persistence, batch state | 150 |
| `cache.dart` | Path cache primitives, TTL, invalidation helpers | 100 |
| `utils.dart` | formatSize, glob matching, sanitization | 50 |
| `api.dart` | Raw HTTP layer (`makeRequest`) + endpoint helpers | 300 |
| `auth.dart` | Login orchestration, 2FA, token refresh | 250 |
| `drive.dart` | Path resolution, listing, mv/rename/trash, restore | 1000 |
| `upload.dart` | Encrypt → push → finalize → drive-entry pipeline | 600 |
| `download.dart` | Download + decrypt + write + timestamp preserve | 450 |
| `webdav_filesystem.dart` | Already exists, leave at root | 600 |
| `cli.dart` | CLI entrypoint + command dispatch only | <2200 |

**State convention:** instance state on a `FilenClient` class in
cli.dart; protocol functions are top-level in their respective
modules and take their dependencies as parameters
(driveApiUrl, bearerToken, cache maps). See
`../internxt-dart/lib/cli.dart` `InternxtClient` class L2106 for
the exact pattern.

**Import prefix convention:** `filen_*` (mirrors internxt's
`inxt_*`). E.g.:
```dart
import 'api.dart' as filen_api;
import 'auth.dart' as filen_auth;
```

**Steps:**
1. Read internxt-dart's `HISTORY.md` Phase 4 section for the
   per-extraction commit pattern. Do extractions in the same order:
   crypto → config → cache → utils → api → auth → drive → upload → download.
2. Each extraction is its own commit; tests (when they exist)
   stay green after each commit. Initially you have no tests, so
   smoke-test by running `dart cli.dart help` after each extraction.
3. After all extractions: cli.dart has only the CLI dispatch + the
   `FilenClient` class holding session state. `cli.dart` re-exports
   the modules so future tests can use `import '../cli.dart';`
   (matches internxt-dart's pattern).

**Acceptance:**
- 10 sibling `.dart` modules at root + `cli.dart` + `webdav_filesystem.dart`.
- `cli.dart` < 2500 LOC.
- `dart analyze` clean with `strict-casts: true`.
- `dart cli.dart help` runs.

---

## Phase 4 — test infrastructure (~3 hours)

**Goal:** establish the test scaffolding. Mirrors what
internxt-dart had after Phase 1 + Phase 9.5. The full test
build-out continues in Phase 5; this phase just unblocks tests
existing.

**Steps:**
1. Create `test/` directory.
2. Add `test` to `dev_dependencies` in `pubspec.yaml`:
   ```yaml
   dev_dependencies:
     test: ^1.24.0
     coverage: ^1.6.0
     lints: ^4.0.0
   ```
3. Write `test/crypto_test.dart` first (the trust roots — Filen's
   crypto: PBKDF2-HMAC-SHA512 → AES-GCM with key derived per-file,
   etc.). Pin the algorithm + parameters with known-vectors tests.
   The Internxt equivalent (`../internxt-dart/test/crypto_test.dart`)
   has 35+ tests; aim for similar coverage on the Filen crypto.
4. Write `test/utils_test.dart`, `test/config_test.dart`,
   `test/cache_test.dart` — pure-function modules.
5. Write `test/cli_test.dart` for any pure CLI helpers (e.g.
   buildMovePlan-equivalent if one exists).
6. Write `test/live_smoke_test.dart` with the **opt-in via .env**
   pattern. Copy the structure from
   `../internxt-dart/test/live_smoke_test.dart`:
   - `_loadDotEnvIfPresent()` walks up to `.env`.
   - Skips cleanly with a "(skipped: ...)" test if `FILEN_EMAIL` /
     `FILEN_PASSWORD` (or whatever the env var convention is) are
     missing.
   - Sentinel folder + per-test unique names.
   - `tearDownAll` cleanup.
7. Add `tool/check_coverage.dart` — copy the script from
   `../internxt-dart/tool/check_coverage.dart`. Set initial
   thresholds:
   - `crypto.dart`: 100%
   - `utils.dart`: 100%
   - Others: not in gate yet (add as coverage grows)
8. `.env.example` at root showing `FILEN_EMAIL=...`, `FILEN_PASSWORD=...`.
9. `.gitignore`: ensure `.env` is ignored (likely already true).

**Acceptance:**
- `dart test test/crypto_test.dart test/utils_test.dart
  test/config_test.dart test/cache_test.dart test/cli_test.dart`
  passes (at least 30 tests).
- `dart test test/live_smoke_test.dart` cleanly skips without
  creds, runs end-to-end with creds.
- `dart run tool/check_coverage.dart` passes against the initial
  threshold list.

---

## Phase 5 — feature parity audit vs filen-python (~3 hours)

**Goal:** identify and port any feature in `filen-python/services/*`
that's missing from filen-dart. Mirror internxt-dart's Phase 5/7/8
arc — the Python sibling is the reference for the protocol.

**Steps:**
1. Compare module surfaces:
   - `filen-python/services/api.py` (273 LOC, 25 defs) → filen-dart `api.dart`
   - `filen-python/services/drive.py` (1784 LOC, 32 defs) → filen-dart `drive.dart`
   - `filen-python/services/auth.py` (225 LOC, 10 defs) → filen-dart `auth.dart`
   - `filen-python/services/crypto.py` (203 LOC, 12 defs) → filen-dart `crypto.dart`
   - `filen-python/services/network_utils.py` (410 LOC, 9 defs) → filen-dart `download.dart` / `upload.dart`
   - `filen-python/services/webdav_provider.py` (393 LOC, 39 defs) → filen-dart `webdav_filesystem.dart`
2. Per-method-name checklist: for each Python public method, is
   there a Dart equivalent? Capture gaps in a per-phase commit message.
3. Likely gap-categories (based on filen-python's commit log:
   "leverage complete trees for find, search, tree", "better caching
   and resuming", "wildcard support"):
   - **Trees-based search/find/tree** — operations that pre-walk the
     full tree once vs. depth-first traversal per query.
   - **Resume support** — batch operations persist state, can resume
     after interruption.
   - **Wildcard support** in CLI commands (glob matching).
3. Port each gap as its own commit. Add a live test for each port.

**Acceptance:**
- `LEARNINGS.md` updated with feature comparison table (mark each
  Python method as: identical, ported, n/a, drift).
- Each ported feature has at least one live test pinning the
  behavior.
- No Python-side feature is silently dropped without justification
  written in PLAN.md.

---

## Phase 6 — lib/ restructure + publish prep (~2 hours)

**Goal:** make filen-dart a real Dart package that cloud-dart can
consume via `dependency: filen_client`. Mirror internxt-dart's
Phase 9.4 (publish-prep) + Phase 6.a (lib/ restructure).

**Steps:**
1. `mkdir lib && git mv api.dart auth.dart cache.dart cli.dart
   config.dart crypto.dart download.dart drive.dart upload.dart
   utils.dart webdav_filesystem.dart lib/`
2. Create `lib/filen_client.dart` (the public barrel):
   ```dart
   library;
   export 'api.dart';
   export 'auth.dart';
   export 'cache.dart';
   export 'config.dart';
   export 'crypto.dart';
   export 'download.dart';
   export 'drive.dart';
   export 'upload.dart';
   export 'utils.dart';
   export 'webdav_filesystem.dart';
   export 'cli.dart' show FilenClient;
   ```
3. Create `bin/filen.dart` (~10 lines):
   ```dart
   import 'package:filen_client/cli.dart' as cli;
   void main(List<String> arguments) => cli.main(arguments);
   ```
4. Update `pubspec.yaml`:
   ```yaml
   name: filen_client
   description: Filen.io cloud storage client + CLI for Dart...
   version: 0.1.0
   homepage: https://github.com/<owner>/filen-dart
   repository: https://github.com/<owner>/filen-dart
   environment:
     sdk: '>=3.0.0 <4.0.0'
   executables:
     filen: filen
   # ... existing deps stay ...
   ```
   Remove `publish_to: none`.
5. Update test imports from `../foo.dart` to
   `package:filen_client/foo.dart` (mechanical sed pass per
   `../internxt-dart` Phase 6.a-0 commit).
6. Update `tool/check_coverage.dart` if it had any path
   references (internxt-dart's used `endsWith('/$name')` so it
   handled the move automatically).
7. `dart pub publish --dry-run` should accept the package shape
   (only "uncommitted files" warning is OK).

**Acceptance:**
- `lib/` directory contains all 11 modules + the barrel.
- `bin/filen.dart` runs as the entry-point: `dart bin/filen.dart help`.
- `dart pub publish --dry-run` accepts the package.
- All tests still pass via package: imports.

---

## Phase 7 — cloud-dart rewire (~3 hours)

**Goal:** delete the embedded copy of filen.dart from cloud-dart;
have cloud-dart consume the published `filen_client` package
instead. Mirror internxt's Phase 6.b/6.c arc — see
`../internxt-dart/AUDIT_6B.md` for the audit pattern and the
load-bearing extension points to verify before the rewire.

### Phase 7.a — cloud-dart audit (~1 hour)

Read-and-classify pass over
`~/code/cloud-dart/lib/services/filen.dart` (4497 LOC) +
sibling files (`filen_client_adapter.dart`, `filen_config_service.dart`,
`filen_web_stub.dart`).

**Output:** `cloud-dart/AUDIT_FILEN.md` (or write to filen-dart's
repo if cloud-dart doesn't want the artifact). Use the same
structure as `../internxt-dart/AUDIT_6B.md`:

1. **What does cloud-dart bring that the published library should
   absorb?** (Web Crypto branches if not already in lib; any
   path-facade extensions; etc.)
2. **What blockers exist for the rewire?** Likely candidates:
   - URL constants need to be configurable (cloud-dart's
     `filen_client_adapter.dart` may pass a custom server URL)
   - Web build needs Flutter SubtleCrypto branches — split into a
     `cloud-dart/lib/services/internxt_flutter/`-style sibling
   - ConfigService extension point for SharedPreferences — see
     internxt's B5 pattern
3. **Per-method parity check** — every method cloud-dart's adapter
   calls on the embedded FilenClient, mapped to the published
   library's surface. Flag any signature mismatches.
4. **GO/NO-GO** verdict.

### Phase 7.b — rewire (~2 hours)

Mirror internxt-dart's `e0eecd2` commit shape. Steps:

1. Add `filen_client` dep to cloud-dart's pubspec.yaml (git ref
   to filen-dart's main, mirror the
   `pubspec_overrides.yaml` pattern from CrispCloud's `4913750`
   commit so local dev still uses path).
2. Replace the embedded protocol class in
   `cloud-dart/lib/services/filen.dart` with a thin re-export shim
   plus any cloud-dart-specific extensions (URLs, Web Crypto if
   not absorbed upstream).
3. Update `filen_client_adapter.dart` to construct a `FilenClient`
   from the package, passing URL / config overrides as needed.
4. Update `filen_config_service.dart` to compose the published
   ConfigService (mirror internxt's B5 ConfigStorage pattern if
   the Flutter Web build needs SharedPreferences).
5. Smoke-test: `flutter analyze` 0 errors, `flutter test`
   passes, `flutter build macos --debug` and `flutter build web`
   both succeed.
6. Add a live smoke test in cloud-dart
   (`test/filen_rewire_live_test.dart`, mirror
   `test/internxt_rewire_live_test.dart` from CrispCloud).

**Acceptance:**
- `cloud-dart/lib/services/filen.dart` reduced from 4497 LOC to a
  small shim (likely <100 LOC).
- `cloud-dart/lib/services/filen.dart` has no protocol code, only
  re-exports + cloud-dart-specific bits.
- All Flutter/CrispCloud tests pass.
- Live smoke test green against real Filen creds.

---

## Phase 8 — CI + GitHub Actions (~30 min)

Mirror `../internxt-dart/.github/workflows/ci.yml`:
- `dart pub get`
- `dart analyze`
- `dart format --output=none --set-exit-if-changed .`
- Unit tests with `--coverage=coverage`
- Coverage gate via `dart run tool/check_coverage.dart`
- Live tests skip via `DART_TEST_SKIP_LIVE: "1"`
- Compile binary smoke check (`dart compile exe bin/filen.dart -o /tmp/filen && /tmp/filen help`)

**Acceptance:**
- `.github/workflows/ci.yml` exists, runs on push + PR to main.
- First CI run completes successfully.

---

## Estimates

| Phase | Effort |
|---|---|
| 0. dedupe | ~30 min |
| 1. de-Flutter | ~1h |
| 2. audit + LEARNINGS | ~2h |
| 3. module split | ~3h |
| 4. test infrastructure | ~3h |
| 5. feature parity vs Python | ~3h |
| 6. lib/ + publish prep | ~2h |
| 7.a. cloud-dart audit | ~1h |
| 7.b. cloud-dart rewire | ~2h |
| 8. CI | ~30 min |
| **Total** | **~18 hours** |

Slightly tighter than internxt-dart's arc because:
- filen-python is already split (no Phase 4-equivalent on the
  Python side needed).
- The audit findings from internxt-dart's LEARNINGS.md transfer
  directly (the bug shapes are the same — `@override` lying
  contracts, dead `_underscore` methods, dynamic dispatch hazards,
  cache invalidation gaps).

## Reference checklist for the executing agent

Before starting any phase:
- [ ] `cd /Users/christianstrobele/code/filen-dart`
- [ ] Read this file's "Status snapshot" + the relevant Phase
- [ ] Skim `../internxt-dart/HISTORY.md` for the equivalent phase
- [ ] Skim `../internxt-dart/LEARNINGS.md` for known gotchas
- [ ] Check git status; commit any in-progress work first

After completing a phase:
- [ ] Update this file's status snapshot ("Done:" section grows)
- [ ] If a new gotcha was discovered, add it to LEARNINGS.md
- [ ] Commit + push + verify CI (once Phase 8 is done)

## Out of scope (explicit non-goals)

- **GUI** — wrong tool for a CLI library.
- **Sync engine** — that's the official desktop client.
- **Cross-account migration** — interesting separate project.
- **iOS / Android-specific binaries** — pure Dart works on those
  platforms via Flutter; the CLI doesn't need to target them
  directly.

## After Phase 7 ships

The `cloud-cli` umbrella idea (Option C from the strategic
discussion that produced this plan) becomes feasible. A new
repository at `~/code/cloud-cli` (or `cloud-dart-cli`) would:

- Depend on `internxt_client` + `filen_client` as packages.
- Provide a uniform `cloud --provider=internxt|filen ls /path` etc.
- Mirror cloud-dart's `CloudStorageClient` interface but headless.

Don't start cloud-cli until Phase 7 lands here — it'd be built on
unstable foundations otherwise.

---

# Performance: connection reuse & concurrency (added 2026-06-29)

Chunk upload/download was **sequential** AND (on upload) opened a **fresh
TCP+TLS connection per 1 MB chunk**. For a 1 GB file (~1000 chunks) that's
~1000 handshakes, serialized. Two independent wins: (0) reuse connections, then
(1) overlap chunks. Applies symmetrically to the sibling `filen-python`.

## Step 0 — connection reuse ✅ DONE & TESTED
- Chunk uploads now go through the pooled `api.client` instead of the one-shot
  top-level `http.post` (`lib/upload.dart`); `http` import dropped. Downloads
  already used `api.client` (`lib/download.dart`). `FilenApi` exposes the single
  reused `http.Client` (`lib/api.dart`).
- (python sibling: `APIClient` now holds one pooled `requests.Session`, shared
  with `DriveService` chunk transfers.)
- Tests: `test/connection_reuse_test.dart` (2 unit) + `live_smoke` (7 live,
  `--tags live --run-skipped`, saved `~/.filen-cli` session). Full unit suite
  219 green. (python: `tests/test_connection_reuse.py` 6 unit + live round-trip.)
- Recovers the bulk of the loss at ~5% of the risk — no architecture change,
  resume feature untouched.

## Step 1 — bounded chunk concurrency ✅ DONE & TESTED
- `lib/upload.dart`: both `uploadFileChunked` and `uploadBytes` dispatch N chunk
  `Future`s gated by a `ChunkSemaphore` (count) **and** the `MemoryGate` (bytes,
  repurposed per-file → per-chunk; `safetyMarginBytes: 0` = pure byte budget, no
  per-chunk `vm_stat`). A sequential producer hashes plaintext in order; only
  the POST is parallel. `lib/download.dart`: `downloadFile`/`downloadFileBytes`
  fetch chunks concurrently (offset writes / ordered slots). Tiny files (≤ 2
  chunks) stay sequential.
- Resume is a **set**: `ChunkUploadException.completedChunks` (+ `fileKey`);
  batch state persists `completedChunks`; `lastSuccessfulChunk` = contiguous max.
- Tests: `test/chunk_concurrency_test.dart` (7 unit) + `test/concurrency_live_test.dart`
  (4 live, `--tags live --run-skipped`). Full unit suite 226 green, `dart analyze`
  clean, coverage gate passes (memory_gate 80%).

Goal: N chunks in flight (start N=4–8), **semaphore-bounded** — never unbounded
(→ server throttling + memory blowup). Mirrors filen-sdk-ts's `MAX_UPLOAD_THREADS`.
- dart: dispatch N chunk `Future`s gated by a semaphore + the **existing
  `MemoryGate`** (`lib/memory_gate.dart`, already byte-budget aware — repurpose
  from per-file `acquire(fileSize)` to per-chunk gating).
- python sibling: `ThreadPoolExecutor(max_workers=N)` (I/O-bound; GIL releases
  during socket I/O).

**Three constraints — do NOT just flip sequential→parallel:**
1. **In-order hashing.** The file hash is a running SHA-512 over *plaintext
   chunks in order*. Keep a sequential producer that reads+hashes in order, then
   hands `(index, plaintext)` to the bounded upload pool. Reading+hashing is
   cheap; only the slow network upload is parallelized.
2. **Resume becomes a set, not a high-water mark.** Today `resumeFromChunk=N`
   assumes all `<N` are done. With out-of-order completion, track a completed-set;
   `ChunkUploadException(lastSuccessfulChunk)` carries the set instead. Protocol
   allows arbitrary chunk order.
3. **Bound by BYTES in flight, not Future count** (critical on mobile/CrispCloud).
   N concurrent chunks ≈ N×(1 MB plaintext + ~1 MB encrypted) live — exactly
   `MemoryGate`'s model. Keep the degree configurable, modest default on mobile.

Skip concurrency for **tiny files** (≤ a few chunks) — branch on size.

## Step 2 — file-level concurrency ⬜ TODO (sync / many small files)
Parallelize whole FILES in batch directory upload/download — the bigger real-world win
when syncing many files. Reference: internxt-dart already does this (`lib/upload.dart`
`runWithConcurrency` pool + `MemoryGate`, `workers=4`) — port that pattern; filen's own
`ChunkSemaphore` / `MemoryGate` (Step 1) compose with it.

Files/functions:
- `lib/upload.dart` → `upload(...)` batch loop (the `for (int i = 0; i < totalTasks;
  i++)` over tasks). Dispatch up to W files concurrently (a `ChunkSemaphore(W)` or an
  internxt-dart-style `runWithConcurrency`). Each file ALSO uses Step 1 chunk
  concurrency, so cap the PRODUCT W×N by passing ONE shared `MemoryGate` instance into
  every per-file `uploadFileChunked` (it is already a per-chunk byte budget) and
  lowering `maxConcurrentChunks` when W>1.
- `lib/download.dart` → `downloadPath(...)` batch loop: same treatment.

CONSTRAINTS:
1. `batchState` + `saveStateCallback` are shared — serialize task-status writes
   (`saveStateCallback` is async; guard with a mutex / 1-permit `ChunkSemaphore`).
2. Cap TOTAL bytes in flight across files × chunks with ONE shared `MemoryGate`, not one
   per file (mobile / CrispCloud).
3. Conflict-check + `createFolderRecursive` per file must stay correct under concurrency;
   progress output must stay readable.

Tests (mirror `test/chunk_concurrency_test.dart` + `test/concurrency_live_test.dart`):
Unit (MockClient): batch never exceeds W files AND the shared byte budget; state writes
race-free. Live (`--tags live --run-skipped`): a many-file directory round-trips + is
faster than W=1. `dart analyze lib/` clean; coverage gate passes.

## Test matrix — unit + live for everything
Unit (hermetic; MockClient):
- [x] chunk POST/GET routes through the pooled `api.client`
- [x] bounded pool never exceeds N concurrent in-flight (assert peak concurrency)
- [x] in-order hash: parallel uploads still produce the correct whole-file SHA-512
- [x] resume-as-set: restart skips exactly completed indices, retries the gaps
- [x] tiny-file path stays sequential
- [x] memory ceiling: `MemoryGate` blocks once byte budget is exceeded
Live (real backend, saved `~/.filen-cli` session, `--tags live --run-skipped`):
- [x] round-trip small file
- [x] round-trip large multi-chunk file (8–16 MB); verify hash + content
- [x] interrupted upload resumes and completes (kill mid-way, restart)
- [x] concurrent throughput sanity (large file faster than sequential baseline)
- [x] directory of many small files round-trips

## Order of work
Step 0 (done) → Step 1 in **filen-python first** (simpler: ThreadPoolExecutor) →
port here with `MemoryGate` → Step 2. Validate each against the matrix before
advancing.
