# filen_client examples

An unofficial Dart client + CLI for Filen.io end-to-end-encrypted cloud
storage. See the package README for full command and API documentation.

## CLI

```sh
FILEN_EMAIL=you@example.com FILEN_PASSWORD=secret \
  dart run filen_client:filen --help
```

## Library

```dart
import 'package:filen_client/filen_client.dart';
// final client = FilenClient(); await client.login('you@example.com', 'secret');
// list / upload / download with batching + resume — see the README.
```
