# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Firewatch is a lightweight Dart/Flutter library providing auth-reactive Firestore repositories. It bridges Firestore with the `flutter_it` ecosystem (`watch_it`, `command_it`, `get_it`) by exposing repositories as `ValueNotifier`s with async CRUD via `command_it` Commands.

Two core repository types:
- **FirestoreDocRepository** — single-document, extends `ValueNotifier<T?>`
- **FirestoreCollectionRepository** — collection with optional live-window pagination, extends `ValueNotifier<List<T>>`

All Firestore models implement the `JsonModel` interface (requires `id` field and `toJson()`).

## Commands

```bash
# Install dependencies
flutter pub get

# Run all tests
flutter test

# Run a single test file
flutter test test/doc_repository_test.dart

# Lint / static analysis
dart analyze

# Generate API docs
dart doc --output doc/api
```

## Architecture

### Source Layout
- `lib/firewatch.dart` — barrel export
- `lib/src/json_model.dart` — `JsonModel` interface, `AuthUidListenable` typedef
- `lib/src/doc_repository.dart` — `FirestoreDocRepository`
- `lib/src/collection_repository.dart` — `FirestoreCollectionRepository`
- `test/` — unit tests using `fake_cloud_firestore`
- `example/` — runnable demo app with Firebase Auth integration

### Key Patterns
- **Auth-reactive**: repos accept any `ValueListenable<String?>` for the user UID; they attach/detach Firestore listeners on UID changes
- **Cache-first streaming**: primes UI from local Firestore cache, then streams live server updates
- **Metadata churn squashing**: uses `mapEquals()` to skip redundant rebuilds from Firestore metadata-only changes
- **Epoch-based race prevention**: incrementing epoch counters discard stale async operations
- **Per-item notifiers**: `notifierFor(docId)` provides efficient detail-view subscriptions without rebuilding the full collection
- **Command pattern**: CRUD operations exposed as `command_it` Commands with built-in loading/error state
- **Extra dependencies**: collection repos support `extraDependencies` (list of `ValueListenable`s) that trigger re-query when changed

### Linting
Uses `package:flutter_lints/flutter.yaml` with additional rules: `prefer_final_locals`, `prefer_const_constructors`, `avoid_print`, `directives_ordering`.
