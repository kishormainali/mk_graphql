# Monorepo Consolidation & Dart Workspaces — Design

Status: approved by user 2026-09-11. Implementation in progress.

## Goal

Replace the current two-separate-git-repos setup (`kishormainali/mk_graphql` and `kishormainali/mk_graphql_generator`, each a standalone clone with its own `.git`) with a single unified `mk_graphql` monorepo, using Dart's native workspace feature for dependency resolution across `packages/mk_graphql`, `packages/mk_graphql_generator`, and `example/`. Update the pub.dev publish workflows accordingly.

## Non-goals

- Preserving git commit history across the merge (user chose a fresh single-commit history for the monorepo; the two source repos' history remains reachable in their existing GitHub repos, which are not deleted).
- Migrating to a third-party monorepo tool (e.g. Melos) — Dart's built-in `workspace:`/`resolution: workspace` fields only.
- Changing pub.dev's trusted-publisher configuration (a pub.dev account setting outside this repo; the user will apply it themselves once the new workflow filenames exist — see "Manual follow-ups").
- Actually pushing to `kishormainali/mk_graphql` or archiving `kishormainali/mk_graphql_generator` — both require overwriting/retiring shared remote state and are explicitly deferred to a separate, explicitly-confirmed step after this implementation is reviewed locally.

## Design

### 1. Workspace layout

Root `pubspec.yaml` (new):

```yaml
name: mk_graphql_workspace
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/mk_graphql
  - packages/mk_graphql_generator
  - example
```

Each member package gains a top-level `resolution: workspace` field and has its `environment` lower bounds bumped to what workspace support actually requires:
- `packages/mk_graphql`: `sdk: '>=3.6.0 <4.0.0'`, `flutter: '>=3.27.0'` (Flutter added workspace support in 3.27).
- `packages/mk_graphql_generator`: `sdk: '>=3.6.0 <4.0.0'`.
- `example`: gains `resolution: workspace`; its `mk_graphql`/`mk_graphql_generator` dependencies change from `path: ../packages/...` to plain version constraints (`^1.0.0`), which pub resolves to the workspace-local copies automatically since they're workspace members.

A single `dart pub get` / `flutter pub get` run from the repo root (or from any member — pub detects the workspace root automatically) resolves all three packages into one `pubspec.lock` / `.dart_tool/package_config.json` at the root.

### 2. Git consolidation (local only in this pass)

1. Remove the nested `.git` directories under `packages/mk_graphql/` and `packages/mk_graphql_generator/` (their GitHub remotes are untouched — confirmed no unpushed local commits exist in either before removal).
2. `git init` at the repo root; add `origin` remote pointing at `https://github.com/kishormainali/mk_graphql.git`.
3. One commit containing the full current tree (both packages, `example/`, `docs/`, new root `pubspec.yaml`, new `.github/workflows/`).
4. **Explicitly out of scope for this pass**: pushing this commit. The target repo already has 2 commits of unrelated history, so pushing this fresh history to `main` requires `--force`, overwriting that history — a separate, explicitly-confirmed action.

### 3. CI & publish workflows

Remove `packages/mk_graphql/.github/workflows/publish.yml` and `packages/mk_graphql_generator/.github/workflows/publish.yml`. Add at the repo root:

- **`.github/workflows/ci.yml`** — on push/PR to `main`, two path-filtered jobs (`paths:` on `packages/mk_graphql/**`/root pubspec files, and on `packages/mk_graphql_generator/**`), each: `flutter pub get` (or `dart pub get`) at repo root, then `dart format --output=none --set-exit-if-changed <package dir>`, `dart analyze` (or `flutter analyze`) and `dart test`/`flutter test` scoped to that package directory.
- **`.github/workflows/publish-mk_graphql.yml`** — trigger: `push.tags: ['mk_graphql-v[0-9]+.[0-9]+.[0-9]+*']`. Same verify/analyze/test steps as CI, then `dart pub publish --force` with `working-directory: packages/mk_graphql`.
- **`.github/workflows/publish-mk_graphql_generator.yml`** — trigger: `push.tags: ['mk_graphql_generator-v[0-9]+.[0-9]+.[0-9]+*']`. Same shape, `working-directory: packages/mk_graphql_generator`.

Both publish workflows keep `permissions: id-token: write` for pub.dev OIDC, and run `dart pub get`/`flutter pub get` at the repo root first (workspace-aware) before their package-scoped steps.

### 4. Manual follow-ups (not performed by this implementation)

Told to the user once the workflow files exist, to do themselves:
1. On pub.dev, update the trusted publisher for `mk_graphql` to repo `kishormainali/mk_graphql`, workflow filename `publish-mk_graphql.yml`.
2. On pub.dev, update the trusted publisher for `mk_graphql_generator` to repo `kishormainali/mk_graphql`, workflow filename `publish-mk_graphql_generator.yml`.
3. Review the locally-committed monorepo, then explicitly decide when/whether to force-push it to `kishormainali/mk_graphql` and archive `kishormainali/mk_graphql_generator`.
4. Going forward, tag releases as `mk_graphql-vX.Y.Z` / `mk_graphql_generator-vX.Y.Z` instead of bare `vX.Y.Z`.

## Testing

- `flutter pub get` / `dart pub get` at the root succeeds and produces one lockfile.
- `dart analyze` and existing test suites still pass for both packages from within their directories under the new workspace resolution.
- `example`'s `flutter analyze` / build still resolves `mk_graphql`/`mk_graphql_generator` correctly via the version-constraint (no `path:`) dependency.
- New workflow YAML is syntactically valid (no execution possible locally, since publish requires pub.dev OIDC and a real tag push).
