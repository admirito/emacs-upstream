# Agent guide

A Makefile drives the build. It fetches GNU's release tarball, checks it against
`keys/`, builds a container image of one Ubuntu release from `Containerfile`, and
runs `build.sh` in it to build Emacs with one toolkit and package it as a .deb in
`out/`. `test.sh` checks the .deb in a clean container.
`.github/workflows/release.yml` runs the same targets for each Ubuntu release and
toolkit and publishes tagged releases. `DESIGN.org` has the reasoning;
`README.org` has the steps of a release.

## Constraints

**POSIX sh.** `build.sh` and `test.sh` run under Ubuntu's `/bin/sh`, which is dash,
and so do the maintainer scripts and the profile file `build.sh` writes. No arrays,
`[[`, `local`, `pipefail` or `${x//a/b}`. `checkbashisms` catches most of them.

**One recipe.** CI runs `make test` and nothing else, so a local build and a
release build are the same build. A step that only CI needs belongs in the
workflow; anything that shapes the .deb belongs in the Makefile or `build.sh`.

**Ubuntu's choices, unless there is a reason.** The build dependencies, the flags,
the gcc and the configure options follow Ubuntu's own emacs package. A departure
needs a reason in `DESIGN.org`.

**Keep out of Ubuntu's lane.** While Ubuntu's emacs is installed, `/usr/bin/emacs`
must stay Ubuntu's: its add-on packages compile with it. This package reaches users
through `PATH` only.

**Trust only `keys/`.** Never verify a tarball against a keyring downloaded beside
it, or skip the check. A key change is a commit of the file as Savannah serves it,
whose message names each new fingerprint and what it was checked against.

## Style

Comments carry the why. Most non-obvious lines exist because of a specific
failure, so name it. US English. No em dashes.

## Testing

`make test` for `UBUNTU=24.04` and `UBUNTU=26.04`, each with `TOOLKIT=gtk3` and
`TOOLKIT=lucid`, after any change to the build or the package. Each takes about ten
minutes, almost all of it the build. A change to `test.sh` alone does not rebuild
the .deb.

When changing the package's alternatives, its maintainer scripts or its `PATH`
files, also break them on purpose, a wrong path or a priority above Ubuntu's 28,
and see `make test` fail.

## Commits

Record the reasoning, not just the change. Never put a session URL, a personal
email address, a hostname, or a machine name in a commit message, a comment, or
any tracked file: this repository is public.
