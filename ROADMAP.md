# 🗺 Roadmap & working notes

Product **facts** live in [README.md](README.md), the **rules** of contributing
in [CONVENTIONS.md](CONVENTIONS.md). This file is the home for everything in
between: what is planned, what needs a decision, and low-stakes todos that
would otherwise rot in an issue nobody opens.

This list is intentionally freeform — edit freely, one line per item, oldest
at the top of each section. Nothing here is a commitment; items graduate when
someone picks them up in an actual PR.

---

## 🚧 In flight

Nothing is mid-flight: bug reports (#164), table chat with GIFs and voice
chat (#165, #168), agent branch-flow rules (#163), and friends — friend
codes, requests, 1:1 chat with likes and replies, play invites, block and
report (#169) — all landed. New sessions pick from **Next up**.

## 📋 Next up

- **Server-side branch protection** — the doc guard stack (hooks + CI jobs)
  stands in for GitHub branch protection; if the repo's plan ever allows it,
  enable "require PR + no force-push" on `main` and `dev` and drop the CI
  duplicates.
- **Delete the legacy `staging` branch** — only after every stale remote
  branch is either merged or deliberately dropped; per convention, trunk
  retirement is a deliberate act, not a script.

## 💡 Ideas / backlog

- Chrome Web Store publishing — the job exists, commented out in ci.yml until
  the paid publisher account is a decision, not a wish.
- Room-code deep links (`?code=XXXX` opening the lobby pre-filled).
- Spectate-only seats for admins to watch a live table from the dashboard.

## 🧹 Housekeeping / known trade-offs

- `prune-branch` semantics for PRs into `dev` depend on the workflow file
  sitting on the **base** branch — dev PRs get pruned the moment this file
  lands on `dev`; `main` gets it with the next release promotion.
- Hosted CI on PRs into `dev` is deliberately absent (metered runner minutes)
  — `tool/ci.sh` locally is the gate; revisit if runner quota ever stops
  being the constraint.
