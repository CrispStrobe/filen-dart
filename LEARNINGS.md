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
