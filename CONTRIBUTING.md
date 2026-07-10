# Contributing to MongrelDB Crystal

Thanks for taking the time to help the MongrelDB Crystal client. This document
describes how to propose a change, what we expect from a pull request, and
the coding standards that apply to the codebase.

If anything here is unclear or out of date, open an issue or a PR.

## Code of conduct

Be kind, be specific, assume good faith. Disagree about the technical
details, not the person. Public reviews stay focused on the diff.

## How to propose a change

The MongrelDB Crystal client uses a standard **fork -> branch -> pull request**
workflow on GitHub.

1. **Fork** [`visorcraft/MongrelDB-Crystal`](https://github.com/visorcraft/MongrelDB-Crystal)
   to your GitHub account.
2. **Clone** your fork and add the upstream remote:

   ```sh
   git clone git@github.com:<you>/MongrelDB-Crystal.git
   cd MongrelDB-Crystal
   git remote add upstream https://github.com/visorcraft/MongrelDB-Crystal.git
   ```

3. **Branch** from `master`. Pick a descriptive, kebab-case branch name:
   `fix-query-alias`, `feature/sparse-vector`, `docs/auth-guide`.

   ```sh
   git fetch upstream
   git switch -c my-change upstream/master
   ```

4. **Make focused commits.** One logical change per commit. Run the
   preflight (see below) before pushing.
5. **Open a pull request** against `master` on `visorcraft/MongrelDB-Crystal`.
   Fill in the PR template:
   - **What.** One paragraph summary of the change.
   - **Why.** Bug fix? New feature? Doc fix? Link the issue if one
     exists.
   - **How to test.** The exact commands a reviewer should run.
   - **Risk.** What might break? What did you not test?

## Before you push: preflight

Run the full CI preflight locally:

```sh
shards install
crystal tool format --check
crystal spec
```

All steps must pass with zero warnings. If a check fails, fix the root
cause - don't silence the linter or skip the test.

To run the live integration suite, set `MONGRELDB_SERVER` to a
`mongreldb-server` binary path and run:

```sh
MONGRELDB_SERVER=./bin/mongreldb-server crystal spec
```

Live tests self-skip when no server binary is found.

## What we look for in a review

- The change does one thing and does it well.
- Behavior changes ship with tests. New client behavior: a unit test
  in `spec/`. Query wire-format changes: cover the exact outgoing
  JSON keys. Daemon-dependent coverage: a live test that skips cleanly
  when no server is available.
- The change keeps this repo a thin client over `mongreldb-server`. Don't
  re-implement storage, indexing, WAL, or SQL planning logic here.
- Documentation is updated alongside the code (`docs/`, `README.md`) if the
  change affects users.
- Commits have clear messages (see below).

## Coding standards

### Crystal

- **Version.** Crystal 1.10 or newer. Don't drop the minimum casually.
- **Dependencies.** No external shards required at runtime - only the
  standard library (`http/client`, `json`). New dependencies must be MIT or
  Apache-2.0 licensed and justified.
- **Errors.** Raise a typed exception hierarchy (`MongrelDBError` base,
  `AuthError`, `NotFoundError`, `ConflictError`, `QueryError`) carrying
  the HTTP status and decoded server envelope, not generic `Exception`s.
- **Naming.** Idiomatic Crystal: `snake_case` methods and variables,
  `PascalCase` classes/modules. Keep `MongrelDB` as the module so callers
  do `MongrelDB::Client.new`, etc.
- **JSON.** NaN and Infinity raise a clear `QueryError` instead of
  corrupting data; the `/sql` endpoint's Arrow IPC bodies are tolerated
  gracefully.
- **URL safety.** Table names interpolated into URL paths must be
  percent-encoded; never concatenate raw caller input into a path.
- **Format.** Run `crystal tool format` before every commit.

### Commit messages

- Subject line: imperative mood, <= 72 characters, no trailing period.
  Example: `Add sparse vector match condition to query builder`.
- Body: wrap at 72 characters. Explain *why*, not *what* (the diff
  shows the what).
- Reference issues with `Fixes #123` / `Refs #123` on a final line
  when applicable.
- **Never** add AI/assistant attribution (no `Co-Authored-By`, no
  `Generated with`, no tool names).

## Issue reports

A useful bug report includes:

- The MongrelDB Crystal client version (from `shard.yml` / shards).
- Your Crystal version (`crystal --version`) and OS.
- The `mongreldb-server` version if the issue involves live requests.
- The exact code or commands that reproduce the issue.
- The expected result and the actual result.
- Any error output or stack trace.

Feature requests are welcome. Please describe the problem you're trying
to solve before proposing the solution.

## Security

If you find a vulnerability, **do not** open a public GitHub issue.
Report it privately through GitHub's private vulnerability reporting -
the repository's **Security** tab -> **Report a vulnerability**. The full
policy is in [`SECURITY.md`](SECURITY.md).

## Licensing

The MongrelDB Crystal client is dual-licensed under MIT OR Apache-2.0. By
contributing, you agree that your changes are made available under the
same license.

- Do **not** paste code from other database clients unless you have done a
  license review first.
- New third-party dependencies must be MIT or Apache-2.0 licensed.

Thanks again - looking forward to your PR.
