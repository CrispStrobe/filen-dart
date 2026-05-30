# Learnings

Lessons learned during filen-dart development, drawn from this project
and from parity work with internxt-dart, internxt-python, and filen-python.

## Architecture

### Monolith-to-modules extraction order matters
Extract **leaf dependencies first** (utils, crypto) then work upward
(config, api, cache, auth, drive, upload/download, cli). Extracting in
the wrong order creates circular dependency tangles.

### The facade pattern preserves backward compatibility
`FilenClient` acts as a facade that delegates to all modules. This lets
existing code (CrispCloud's `FilenClientAdapter`) continue calling
`client.resolvePath()` etc. without knowing about the internal module
split. New code can import individual modules directly.

### Dependency injection must be designed in from the start
Adding `http.Client?`, `ConfigStorage`, `DateTime Function()` (clock),
and `Random?` injection points made every module independently testable.
Without these, the only way to test crypto was to hit the real API.

## Filen Protocol

### Metadata encryption uses a non-standard PBKDF2 trick
Filen derives encryption keys via `PBKDF2(key, key, 1, 32)` — using the
key itself as both password and salt, with 1 iteration. This is
effectively a deterministic key-expansion step, not true PBKDF2 hardening.
Auth key derivation uses 200,000 iterations with a proper salt.

### The flat tree API is critical for performance
`/v3/dir/tree` returns the entire folder hierarchy in one call. Without
it, listing a folder with 100 subfolders requires 100+ sequential API
calls. All search, find, tree, and batch download operations use this.

### File format: `002` + 12-char IV + base64(ciphertext+tag)
The `002` prefix indicates metadata format version 2 (AES-256-GCM).
Earlier versions used different schemes. The IV is a 12-character ASCII
string (not raw bytes), which limits the IV space but is Filen's standard.

### Chunk uploads use encrypted-chunk hashing
Each 1MB chunk is encrypted, then the SHA-512 hash of the **encrypted**
chunk is sent as a query parameter. This lets the server verify integrity
without being able to decrypt content.

## Testing

### Real crypto with mocked network is the sweet spot
internxt-dart and internxt-python both use this pattern: actual
encryption/decryption in tests, but mock the HTTP layer. This catches
real crypto bugs (wrong IV size, key encoding) while keeping tests fast
and reproducible.

### Per-file coverage gates beat global thresholds
A global 80% threshold lets crypto slip to 50% as long as utils is at
100%. Per-file gates (crypto=90%, api=30%, cli=5%) match the testability
of each module — pure functions get high thresholds, network-dependent
code gets lower ones.

### Live tests must be self-cleaning and isolated
All live tests create a unique sentinel folder
(`/__test_filen_dart_smoke__/<timestamp>/`) and clean up on teardown.
This prevents test pollution across runs and makes it safe to run
against a real account.

### Live tests can reuse a saved CLI session (no password needed)
`test/live_support.dart` authenticates via `FILEN_EMAIL`/`FILEN_PASSWORD`
**or**, when those are absent, a saved CLI session
(`~/.filen-cli/credentials.json`). The session holds the long-lived apiKey
+ decrypted master keys, so `setAuth()` is enough — the raw password is
never stored and never needed. CI stays clean: with no env creds and no
saved session the suite skips. Note the `live` tag is `skip:`-configured in
`dart_test.yaml`, so running them locally needs `--tags live --run-skipped`.

### Known-answer vectors are the only real guard for hand-rolled crypto
filen-dart's PBKDF2 is hand-written (HMAC block + XOR loop), not a library
KDF. Determinism/length assertions would pass even if the block index or
XOR were wrong. The fix: pin exact output bytes against vectors computed
independently with Python's `hashlib` (PBKDF2-HMAC-SHA512, `deriveKeys`
v1/v2, HMAC filename hashing). Include a >64-byte case to exercise the
multi-block path.

### Glob-to-regex conversion must escape every non-wildcard character
A naive `pattern.replaceAll('*', '.*').replaceAll('?', '.')` leaves regex
metacharacters (`.`, `+`, `(`, `[`, `$`, `|`) live, so `a+b.txt` matches
`aaab.txt` and `file(1).*` throws. Translate only `*`/`?` and run every
other character through `RegExp.escape`. This bug existed twice (utils and
drive.findFiles) — a sign the helper should have been shared from the start.

### "Adapt, don't blindly port" when the sibling uses a different protocol
internxt-dart sets the *thoroughness* bar, but Internxt and Filen differ in
crypto (CBC/CTR vs GCM), endpoints, and metadata format. Port a test by its
*intent*, not its literal assertions: keep round-trip/tamper/size-matrix
behaviors, drop algorithm-specific vectors (OpenSSL `Salted__` headers,
bucket/mnemonic key derivation) that have no Filen analog.

### A returns-`Never` helper unlocks flow analysis (and surfaces dead code)
Changing `_exit` from `void` to `Never` let the analyzer promote nullables
after guard clauses (fixing a real `String?` error) and immediately flagged
the now-unreachable null-checks downstream. Cheap, correct, and revealing.

## Cross-project patterns

### Git dependencies for sibling libraries
Both internxt-dart and filen-dart are consumed by CrispCloud via git
dependencies in `pubspec.yaml`, with `pubspec_overrides.yaml` (gitignored)
for local development. This avoids stale embedded copies while still
allowing fast local iteration.

### The adapter pattern isolates protocol differences
CrispCloud uses `CloudStorageClient` as an abstract interface with
`FilenClientAdapter`, `InternxtClientAdapter`, `SFTPClientAdapter`, and
`WebDavClientAdapter`. Each adapter translates between the generic
interface and the protocol-specific client. This made swapping from an
embedded copy to a library dependency a 3-file change.
