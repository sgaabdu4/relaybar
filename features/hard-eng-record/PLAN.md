# Point the Hard Eng record at the rewritten release

Status: Complete

## Outcome + scope

Hard Eng's history was rewritten on 2026-11-07 to remove private names from its plan files. The release this project records got a new ID, so Hard Eng updates would fail with "not older than". The record now names the new ID of the same release. Non-goals: a Hard Eng update, other files.

## Repository context

Owners: `.hooks/hard-eng-source.json` (installed release record).
Same cause: N/A — one record; the old and new release differ only in Hard Eng plan files that are never installed.

## Decisions + authorization

Blockers: None.
Handoff: Approval
Authority: Abid on 2026-11-07: "YES FUCKING DO IT!!!" to the Hard Eng history rewrite and its follow-up repairs; merge after green checks.
Decision: change only the recorded revision; the installed files already match the new release.

## Acceptance + steps

- [x] The record names a release on Hard Eng main with the same installed files → N/A — proven by `python3 .hooks/hard-eng.py update` after merge, not a project test.
- [x] The project's gates still pass → N/A — proven by `python3 .hooks/hard-eng.py check` and CI, not a new test.

## Baseline + execution

Result: Passed
Evidence: the same update in another project failed on 2026-11-07 with "Recorded Hard Eng release … is not older than …"; main passed its required CI.
Execution: one session; edit the record, full check, PR, merge on green.

## Risks + recovery

A wrong ID would block updates again. Recovery: revert this pull request.

## ux_reference

N/A — no screen changes; a tooling record.

## Verification

Result: Passed
Evidence: `python3 .hooks/hard-eng.py check --plan-stage Complete --base origin/main` result recorded in the pull request.
E2E: N/A — no app behavior changes.
Delivery target: PR
Delivery: Pending — PR into main.
