# Installing an exact or older cac version

`install.sh` does not install a chosen cac version, commit or ref, and the
repository does not publish tags or releases so that every `cac --version`
value can be downloaded again. The installer installs the newest cac, and
`cac update` moves an existing install up to the newest one.

## Why this is out of scope

The owner decided on 2026-11-15 (#140) that the newest version is the only
version anyone should install. Making two hosts match means bringing both up
to the newest cac (`cac update`), not pinning one host to the other's older
build.

Choosing an older version would only matter to someone who keeps hosts on old
builds on purpose, and this fleet does not do that. Adding a `--version` or
`--ref` option would bring work without benefit: mapping a `YYMMDD-HHMM`
version back to a commit, making checksums work for any ref, documenting the
downgrade path, and keeping all of it tested.

```bash
# Version parity across hosts: update both, compare afterwards
cac update
cac --version
```

The version string itself has to stay unambiguous. One commit must get the
same version on every install path. That part of #140 is a bug and is handled
in that issue (all version strings in UTC).

## Prior requests

- #140: "Exact historical CAC versions cannot be installed reproducibly"
