# Changelog

## 0.2.1 — Web compatibility fix

### Fixed
- **Web builds no longer pull in `dart:ffi`.** `aes_gcm_backend.dart` imported
  the OpenSSL and Windows-CNG FFI backends unconditionally, so any web
  (dart2js/dartdevc) consumer failed to compile with *"Dart library 'dart:ffi'
  is not available on this platform"*. The FFI backends are now selected via a
  conditional import (`if (dart.library.ffi)`) with web-safe stubs; on web the
  chooser falls through to the WebCrypto-backed `CryptographyBackend`. No API or
  behavior change on native platforms.

## 0.2.0 — Bounded chunk + file-level concurrency

Chunk and file transfers now run with **bounded concurrency** instead of
one-at-a-time — the single biggest throughput win for the client.

### Added
- **Bounded chunk concurrency (Step 1):** uploads (`uploadFileChunked`,
  `uploadBytes`) and downloads (`downloadFile`, `downloadFileBytes`) transfer
  multiple 1 MB chunks in parallel, bounded by a `ChunkSemaphore` (count) **and**
  the `MemoryGate` (bytes in flight). Configurable via `maxConcurrentChunks`
  (default 4).
- **File-level concurrency (Step 2):** batch directory upload/download transfer
  multiple whole files at once, sharing one global memory budget.

### Fixed
- Resume now tracks a completed-index **set** (safe with out-of-order chunk
  completion) and reuses the original file key on restart — previously a fresh
  key made already-uploaded chunks undecryptable.

### Preserved invariants
- In-order whole-file SHA-512 hashing (parallel uploads produce the identical
  hash to the sequential path); tiny files stay on the simple sequential path.

### CI
- Pinned Dart SDK, `coverage` dev-dependency, per-job timeouts, `workflow_dispatch`.

## 0.1.0

- Initial release: chunked upload/download with resume, batch operations,
  recursive transfers, conflict handling, integrity verification, WebDAV server.
