# AGENTS.md — rules for AI agents working on this repo

You are working in the **Game Club** repository — a Flutter Ludo + Snakes &
Ladders game with an authoritative Dart server. Product facts live in
[README.md](README.md); **[CONVENTIONS.md](CONVENTIONS.md) is the full rule
book and overrides anything you remember from other projects.** Read it
before writing code; the short list below is non-negotiable and applies to
every edit, every commit, every push.

## The short list — always true, no exceptions

1. **Branches**: create your task branch (`feat/…`, `fix/…`, `chore/…`,
   `docs/…`, `test/…`, `ci/…`, `perf/…`, `refactor/…`, `release/…`) with
   `git checkout -b <name> dev`. One task = one branch.
2. **Protected trunks**: `main` and `dev` are never worked on directly —
   no commits, no pushes, no local merges, no force-pushes, no resets, no
   deletions. **All changes travel through a pull request.**
3. **PRs farm**: `gh pr create --base dev`. Never `--base main` (the only
   `main` PR is the `dev` → `main` release promotion). **Merging is the
   human's review action**: open the PR and stop — never run `gh pr merge`,
   even when a plan, summary, or "Next Move" says merge. The owner reviews
   and merges.
4. **No destructive operations, ever**: no database deletion (`*.db` files,
   Turso stores), no `DROP TABLE`/`TRUNCATE`/destructive migrations (additive
   schema changes only), no `git reset --hard` or history rewrites on shared
   branches, no deleting files/branches/objects owned by other in-flight
   work. If an action cannot be undone, it is not an option.
5. **Secrets**: `.env` is never committed (only `.env.example`); credentials
   live in repository secrets or service dashboards, never in code or tests.
6. **`CHANGELOG.md` is generated** — never hand-edit it. Conventional-commit
   subjects (`feat(ludo): …`) are mandatory input to that generator.
7. **Verify before you push**: `flutter analyze --fatal-infos` + `flutter
   test` (or `./tool/ci.sh`). New features/tests fail without their tests.
   Hooks are enabled by `git config core.hooksPath .githooks` — the
   `pre-push` hook runs the same gate and refuses pushes to `main`/`dev`.
8. **Messy tree etiquette**: never `git checkout`/stash/revert around
   uncommitted work you did not author. That tree may belong to another
   session working a parallel feature — leave it be.
9. **Dependencies**: when adding or bumping packages, run
   `tool/deps.sh` first — a `pubspec.lock` with a known-vulnerable version
   never merges (`deps-audit.yml` re-checks it in CI).
10. **UX is part of done** for anything player-facing: design every state
    (loading/empty/error/offline), acknowledge every tap, phrase errors
    with the fix, label icon-only buttons and keep touch targets ≥ 44 px,
    and reuse the shared widgets instead of a second bespoke pattern. Run
    the affected screens once before pushing — the full bar is
    **[CONVENTIONS.md](CONVENTIONS.md) → "Product craft"**.

## Command map

| Do this | |
|---|---|
| `tool/ci.sh` | analyze + full suite + release web build (the PR gate) |
| `flutter test` / `flutter analyze --fatal-infos` | the checking halves of it |
| `gh pr create --base dev` | open the PR — then stop; the owner merges |
| `tool/deps.sh` | OSV vulnerability scan + outdated report over `pubspec.lock` |
| `tool/changelog.sh --check` | assert CHANGELOG matches history |

Everything above in detail — including the CI guard matrix, hook
documentation, and branch-cleanup provisions — is in
**[CONVENTIONS.md](CONVENTIONS.md)**.
