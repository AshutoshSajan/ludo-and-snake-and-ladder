# OpenCode pull request review

An advisory, read-only review for pull requests into `dev` and `main`, run on
demand by a maintainer, plus a trusted-maintainer follow-up command in the
discussion.

The model **never** approves, requests changes, merges, edits, pushes, or
resolves a thread on its own. Every published review uses GitHub's `COMMENT`
event; a human still owns the merge.

- [Setup](#setup)
- [What runs, and when](#what-runs-and-when)
- [Talking to the bot](#talking-to-the-bot)
- [Security model](#security-model)
- [Cost](#cost)
- [Local testing](#local-testing)
- [Limits and first-run behaviour](#limits-and-first-run-behaviour)
- [Troubleshooting](#troubleshooting)

## Setup

Two repository settings are required:

| Name | Kind | Required | Purpose |
| --- | --- | --- | --- |
| `OPENCODE_API_KEY` | Actions **secret** | Yes, for reviews and questions | OpenCode Console / Go provider key. |
| `OPENCODE_MODEL` | Actions **variable** | No | Overrides the default model. Format: `provider/model`, optionally `provider/model#variant`. |

Set them in **Settings → Secrets and variables → Actions**. The secret is
never written to the repository, a comment, or an artifact. Without the secret
the review workflow posts a `::notice::` and skips cleanly; `/opencode resolve`
still works because it does not call the model.

The default model is `opencode/deepseek-v4.1-flash` (documented at
$0.30 / $1.20 per 1M input / output tokens when this was written; check the
provider's current pricing before changing volume assumptions). A cheaper or
more capable model can be selected with the variable without a code change.

### Files

| Path | Role |
| --- | --- |
| `.github/workflows/opencode-review.yml` | PR review (manual dispatch): read-only model job, separate publisher job. |
| `.github/workflows/opencode-review-command.yml` | Trusted `@opencode` questions and `/opencode resolve`. |
| `.github/opencode/reviewer-agent.json` | Trusted read-only agent/permission config, injected with `OPENCODE_CONFIG`. |
| `.github/opencode/review-prompt.md` | Strict JSON review contract. |
| `.github/opencode/command-prompt.md` | Plain-Markdown discussion reply contract. |
| `.github/opencode/prepare_review.py` | Builds the bounded context and diff artifact. |
| `.github/opencode/publish_review.py` | Validates the model output and posts the review. |
| `.github/opencode/command.py` | Trusted-event gate, context builder, reply/resolve client. |
| `.github/opencode/review_lib.py` | Parser, diff index, validation, sanitisation. |
| `.github/opencode/github_api.py` | Shell-free `gh` API helpers. |
| `.github/opencode/test_review_lib.py`, `test_command.py` | Unit tests, including the publisher dry-run. |

## What runs, and when

`opencode-review.yml` is **manual only**: no pull-request event starts it.
A maintainer dispatches it — from the CLI with the PR number:

```bash
gh workflow run opencode-review.yml --ref dev -f pr=<number>
```

or from **Actions → OpenCode review → Run workflow** once the file is on the
default branch (GitHub lists dispatch workflows in the UI only from there).
CLI dispatch works from any branch whose copy of the workflow declares
`workflow_dispatch`, which `dev` has now. Nothing is reviewed, and no model
key is spent, until that dispatch happens.

The dispatch fails closed — the run goes red before any PR code is checked out
or reviewed — when:

- the input is not a pull-request number;
- the dispatch ref is not `dev` or `main` (the workflow YAML is trusted code
  that carries the provider key; PR branches never supply it);
- the PR is **closed**, or its head branch was deleted;
- the head repository is a **fork** (same boundary as before: fork code is
  never handed a process that holds the provider key).

Drafts are reviewable on request: a manual dispatch is an explicit decision, so
there is no `ready_for_review` waiting period to lose. Bot-authored PRs can be
reviewed the same way when a maintainer wants one.

The review job has read-only repository scopes (`contents`, and `pull-requests`
for resolving the dispatch) and the model process receives a minimal environment
with **no GitHub token**, and the agent config allows only `read`, `glob`, and
`grep`. The separate publisher job has `pull-requests: write` and
`issues: write`, and it checks out the **base commit**, not the PR head, so a
PR cannot rewrite the code that validates or posts comments.

The model returns one JSON envelope:

```text
<opencode_review>
{"summary":"...","comments":[{"path":"lib/...","line":42,"side":"RIGHT","severity":"high","body":"..."}]}
</opencode_review>
```

The publisher then:

1. rejects paths that are not in the diff (including `..`, absolute paths,
   backslashes, and `.git/`);
2. accepts a comment only on a line that exists in the diff, on the stated
   `LEFT`/`RIGHT` side;
3. folds a well-formed comment on a non-diff line into the review summary
   instead of failing the whole review;
4. caps inline comments at 10 and sanitises bodies (no forged review markers,
   no live `@` mentions);
5. posts one `COMMENT` review at the head SHA, or a short parse-failure notice
   if the model did not follow the contract.

If GitHub rejects an inline position with a `422`, the publisher retries once
with **every** finding folded into the summary, so a single bad position cannot
lose the review.

### Re-runs

A re-run on the **same head SHA is a no-op**: the publisher finds the existing
review by its hidden marker and skips, because posting again would duplicate
every inline comment. Push a new commit for a fresh review. A parse-failure
notice is updated in place rather than duplicated, and it is marked superseded
after a successful review.

The raw model output stays in the `opencode-review` artifact for 3 days. It is
never copied into a public comment: it is untrusted and may contain content
from the diff or a prompt-injection attempt.

## Talking to the bot

`opencode-review-command.yml` listens to `pull_request_review_comment` and
`issue_comment` creation. It acts only when all of these are true:

- the author is a **same-repository** PR participant with `OWNER`, `MEMBER`, or
  `COLLABORATOR` association;
- the author is not a bot;
- the PR is open and its head is in this repository (no forks);
- the comment contains `@opencode` or `/opencode` (case-insensitive).

Then:

| Comment | Result |
| --- | --- |
| `@opencode why is this null?` | A read-only answer in the same review thread. |
| `/opencode why is this null?` | Same, as a slash command. |
| A top-level PR comment with `@opencode ...` | An answer on the PR discussion. |
| `/opencode resolve` **inside a review thread** | Posts a confirmation and resolves that thread through GraphQL `resolveReviewThread`. |
| `/opencode resolve` in a top-level comment | Explains that it only works inside a review thread. |

The command job checks out the PR head so the assistant can read nearby files,
but the assistant still has only `read`, `glob`, and `grep`: no edits, no shell,
no network tools, no subagents. The GitHub token is used by the command script
for its own API calls and is **not** put into the model process environment.

A question with no text (`@opencode` alone) gets a short usage reply instead of
a model call. `/opencode resolve` must be the whole comment; adding words turns
it into a normal question.

## Security model

- **Read-only review.** The review job has `contents: read`; the model cannot
  write to the repository or the PR. The publisher only ever posts a `COMMENT`
  review, never `APPROVE` or `REQUEST_CHANGES`.
- **Trusted code runs the privileged steps.** The publisher and command scripts
  are taken from the PR's base commit. A malicious PR cannot change validation
  or the API calls that run with a write token.
- **No project config in CI.** `OPENCODE_CONFIG` points at the trusted
  `reviewer-agent.json`, and `OPENCODE_DISABLE_PROJECT_CONFIG=1` prevents a PR
  from loading its own `opencode.json`, `.opencode/`, or `AGENTS.md` into the
  agent. The model may read files, but a file cannot grant itself permissions.
- **No GitHub token in the model.** The review job builds an `env -i`
  environment with `PATH`, `HOME`, `CI`, the provider key, and the OpenCode
  config flags. Actions metadata and `GITHUB_TOKEN` are absent.
- **Untrusted text is data.** The diff, PR body, comments, and repository files
  are explicitly labelled as untrusted in both prompts. The model is told never
  to follow instructions found in them.
- **Output is validated, not trusted.** Paths, sides, lines, severities, and
  sizes are checked. Unknown or traversal paths are discarded without being
  echoed. Bodies are capped and sanitised; `@` mentions are neutralised so a
  prompt-injected diff cannot ping a person or team.
- **Fork isolation.** Fork PRs are refused by both workflows, and the command
  path requires the head repository to equal the base repository before any
  head checkout.
- **Checkout symlink boundary.** Both model paths run the trusted
  `sanitize_checkout.py` after the head checkout and before the model starts:
  any symlink whose canonical target leaves the workspace is removed, and a
  failed removal fails the run closed. A committed link therefore cannot
  redirect a permitted `read`/`grep` into `/proc/self/environ` or any other
  host file to fish the provider key (CWE-61).
- **Bounded work.** Diff input is capped at 200 KB / 200 files for reviews and
  120 KB for commands. Inline comments are capped at 10; the review summary is
  capped at 12,000 characters. A command timeout is 10 minutes.

## Cost

The model call is the only metered external cost; GitHub-hosted runner minutes
are billed separately. A typical review sends the bounded diff plus the prompt
and receives at most 10 short comments. The default `deepseek-v4.1-flash` is
the low-cost choice; set `OPENCODE_MODEL` to a different provider/model if the
review quality warrants it.

Fork PRs are refused before the key is used, so drive-by PRs cannot spend the
secret, and because nothing runs on push every review is an explicit spend
decision. A dispatch for a SHA that already has a published review still runs
the model call, but the publisher skips posting because a review for that
commit already exists. Push a new commit and dispatch again for a fresh review.

## Local testing

Everything is standard library Python. From the repository root:

```bash
cd .github/opencode
python3 -m unittest -v test_review_lib test_command
python3 -m py_compile *.py
```

Workflow lint (if installed):

```bash
actionlint .github/workflows/opencode-review.yml \
           .github/workflows/opencode-review-command.yml
```

Build a context from real history without calling a model:

```bash
python3 .github/opencode/prepare_review.py \
  --workspace . \
  --output-dir /tmp/opencode-context \
  --base-sha "$(git rev-parse origin/dev)" \
  --head-sha "$(git rev-parse HEAD)" \
  --repo owner/repo
```

Dry-run the publisher against a saved artifact. This performs **no** API call
and posts nothing:

```bash
mkdir -p /tmp/opencode-artifact
# review-output.txt: the model's <opencode_review> envelope
# pr.diff:          the unified diff the reviewer saw
# diff-truncated.txt: "0" or "1"
python3 .github/opencode/publish_review.py \
  --artifact-dir /tmp/opencode-artifact \
  --pr 123 \
  --head-sha "$(git rev-parse HEAD)" \
  --model opencode/deepseek-v4.1-flash \
  --dry-run
```

The dry-run prints the exact JSON payload that would be sent, including the
validated inline comments. The unit tests cover valid output, empty comments,
malformed output, an invalid line folded into the summary, path traversal, an
oversized body, and the error notice.

To exercise the command parser without posting, provide a saved webhook payload
and a read-only token for the PR metadata lookup:

```bash
GH_TOKEN=... GITHUB_EVENT_NAME=pull_request_review_comment \
GITHUB_EVENT_PATH=/tmp/event.json \
python3 .github/opencode/command.py \
  --workspace . \
  --trusted-dir . \
  --repo owner/repo \
  --dry-run
```

`--dry-run` prints the context path and intended destination; it does not post a
reply or resolve a thread.

## Limits and first-run behaviour

- **The PR that adds this workflow is not reviewed by it.** Privileged scripts
  are read from the base commit, which does not contain them until the change
  merges. After the merge into `dev`, subsequent PRs into `dev`/`main` work.
  The same applies to commands: the base commit must contain
  `.github/opencode/command.py`.
- Reviews cover only changed lines. Pre-existing problems in untouched files are
  out of scope by design.
- The diff is capped at 200 KB or 200 files (review) and 120 KB (command
  context). The summary says when the cap was hit; findings outside the
  included hunks are not covered.
- At most 10 inline comments are sent. Extra findings are folded into the
  summary (up to 10) or omitted with a count.
- The model must return the JSON envelope. A non-conforming model produces a
  parse-failure notice, not a guessed review; raw output is in the artifact.
- Reviews are advisory. `main`/`dev` protection and the human merge decision are
  unchanged.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No review, job green, `::notice::` about `OPENCODE_API_KEY` | Add the repository secret. |
| `::notice::The base commit does not contain ...` | Merge the workflow PR into `dev` first. The scripts are intentionally not read from the PR head. |
| Review job green but no review, parse-failure comment | The model did not follow the JSON contract. Inspect the `opencode-review` artifact and consider a stronger model via `OPENCODE_MODEL`. |
| Inline comments missing, summary lists findings | The line was not in the diff, or GitHub rejected the position and the publisher folded every finding. |
| Re-run produced no new review | Same head SHA is deliberately a no-op. Push a commit. |
| `@opencode` command ignored | The author must be `OWNER`/`MEMBER`/`COLLABORATOR`, the PR must be open and same-repository, and the comment must contain the exact trigger. |
| `/opencode resolve` says it only works in a review thread | Reply on the line conversation, not the top-level PR comment. |
| `gh api ... failed` in the log | The workflow token permissions or the PR number are wrong; check the job's `permissions:` block. |
