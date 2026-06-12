# Contributing

## Development

```bash
flutter pub get            # install deps
flutter analyze            # static analysis (must be clean)
flutter test               # run the test suite
flutter test --coverage    # with coverage → coverage/lcov.info
```

CI (`.github/workflows/ci.yml`) runs `analyze` + `test` on every pull request
and on pushes to `main`, and enforces a **90% line-coverage** floor.

## Releasing

Releases are **tag-driven**. Pushing a `vX.Y.Z` tag triggers two workflows in
parallel:

- `release.yml` — verifies the tag matches `pubspec.yaml`, runs analyze/test,
  and creates the GitHub Release from the matching `CHANGELOG.md` section.
- `publish.yml` — publishes the package to [pub.dev](https://pub.dev/packages/firewatch)
  via OIDC.

Steps:

1. In a PR: bump `version:` in `pubspec.yaml` and add a `## X.Y.Z` section to
   `CHANGELOG.md`. Merge to `main`.
2. Tag the merge commit and push the tag:

   ```bash
   git checkout main && git pull
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

> **Why a human-pushed tag?** A tag created by a workflow using the default
> `GITHUB_TOKEN` does **not** trigger other workflows (GitHub prevents recursive
> runs), so `publish.yml` would never fire. Pushing the tag from your own
> credentials drives both workflows without needing a Personal Access Token.

The tag and `pubspec.yaml` version **must match**, or `release.yml` fails fast.
