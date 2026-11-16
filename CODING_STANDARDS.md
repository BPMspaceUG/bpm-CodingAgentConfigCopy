# Coding standards

Rules a reviewer checks on every change (`/code-review` reads this file).

## Credential and config parsers

- New or changed code that parses a tool's credential or config file is tested against a real-shape fixture from `tests/fixtures/`.
  A real-shape fixture has the keys, nesting, key order and line layout the tool actually writes; a toy shape such as `{"m":"creds"}` does not count.
  `tests/fixtures/README.md` records where each fixture's shape came from and which parts are guessed; a new fixture adds its row there.
  Why: the #141 session parser passed its own tests and broke on a real `.claude/.credentials.json` where `mcpOAuth` precedes `claudeAiOauth` (#144).
- Fixtures hold no real secrets. Every token, key and account id is a placeholder that says `FIXTURE`, or a nil UUID.
  Build a new fixture from the real file's structure only, for example `jq 'paths(scalars) as $p | [$p, (getpath($p) | type)]'`, not by editing a copied real file.
  Check before committing: `grep -L FIXTURE tests/fixtures/*.json` lists nothing.

## Parsers of another program's output

- The fixture rule above also covers code that parses another program's output: package managers (`dpkg -S`, `rpm -qf`, `apk info -W`), a tool's `--version`, any CLI.
  The test feeds the parser a sample captured from the real program, kept verbatim in `tests/fixtures/`; a stub that echoes a line written from memory does not count.
  `tests/fixtures/README.md` records the image or host, the command and the date of each capture.
  Capture the edge shapes as well as the happy path: the "not found" message and which stream it goes to, and any extra lines the program prints first.
  Why: `_env_package_owner` (#148) was tested only against a hand-written dpkg stub. The real `dpkg -S` prints diversion lines before the owner line, and the parser named "diversion by foo from" as the package (#157).
