# Building and distribution

Pyroquet 0.1.0 is distributed as source on
[GitHub](https://github.com/idlab-discover/pyroquet). The release includes GitHub's
source archives. No PyPI or Conda channel package is published by this project.

## Reproducible setup

The supported target is Linux x86-64. Install Git, Python 3, Pixi 0.80.0 and
uv 0.12.10, then run `python3 tools/bootstrap.py` from a clean checkout.
Bootstrap fetches missing sibling dependencies over HTTPS, verifies their exact
revisions, installs the locked Pixi environment and sets up pinned independent
readers in `build/oracle-uv`. Existing dependency checkouts must match the pins
and have no tracked changes; mismatches are left unchanged.

| Dependency | Pinned revision or version |
|---|---|
| Mojo | 1.0.0 |
| NuMojo | `515fb2856f0ecf3d2740a34d958fe168183e1129` |
| mojo-snappy | `ad02f439892d7b7813677d94f8e0951be63d0041` |
| MAX core (required by NuMojo) | 26.5.0 |
| zlib | 1.3.2 |
| ZSTD | 1.5.7 |

Keep the checkout in its installed location. If it moves, run
`pixi reinstall --locked` to regenerate toolchain paths before rebuilding.

## Build and consume the library

```sh
pixi run --locked package          # build/pyroquet.mojoc
pixi run --locked package-compact  # build/compact_protocol.mojoc
```

From this checkout, compile an application from source:

```sh
pixi run --locked mojo build -I src -I ../NuMojo app.mojo -o build/app
pixi run --locked ./build/app
```

To import the precompiled packages instead, build both packages above and use
`-I build` in place of `-I src`. NuMojo's source include and the locked environment
are still required. Use absolute include paths when building elsewhere.

The `.mojoc` files are tied to the pinned Mojo toolchain. They are not standalone
executables or self-contained installations. Run consumers through Pixi to use
the matching Mojo runtime and codec libraries. Python is used for development
and qualification, not library execution.

## CI and release qualification

GitHub Actions uses pinned action revisions and Pixi 0.80.0 on Ubuntu 24.04.
Every run performs ordinary qualification. Runs on `main` and version tags also
perform the mandatory large-file gate using the same frozen exporter. On other
branches, manual dispatch can enable large qualification.

The workflow uploads qualification reports and stdout/stderr logs, including
independent writer results. It does not publish a package to a channel or create
a GitHub release. See the [qualification workflow](../tests/release/README.md)
for the checks and evidence contracts.

For a release, commit the final source, documentation and assets together as a
reviewable release increment. Qualify that exact clean commit with both gates,
then create an annotated version tag and publish a GitHub release with the
release notes. Do not move an existing release tag. Known oracle limitations
must remain visible in the release description.
