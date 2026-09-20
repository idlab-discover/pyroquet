# Third-party notices

Pyroquet is licensed under Apache-2.0; see [LICENSE](LICENSE). Dependency
licenses remain applicable to their respective code. These notices preserve the
licenses for the pinned release dependencies and development corpus.

| Component | Pinned source/version | License and retained notice |
| --- | --- | --- |
| [NuMojo](https://github.com/Mojo-Numerics-and-Algorithms-group/NuMojo) | `515fb2856f0ecf3d2740a34d958fe168183e1129` | [Apache-2.0 with the upstream LLVM exceptions](licenses/NUMOJO-LICENSE) |
| [mojo-snappy](https://github.com/idlab-discover/mojo-snappy) | `ad02f439892d7b7813677d94f8e0951be63d0041` | [Apache-2.0](licenses/MOJO-SNAPPY-LICENSE); [Google Snappy BSD-3-Clause notice](licenses/MOJO-SNAPPY-THIRD-PARTY-NOTICES.md) for the upstream-adapted algorithms |
| [zlib](https://zlib.net/) | `1.3.2` | [zlib license and copyright notice](licenses/ZLIB-LICENSE) |
| [Zstandard](https://github.com/facebook/zstd) | `1.5.7` | [BSD-3-Clause license and copyright notice](licenses/ZSTD-LICENSE) |
| [Fastparquet golden corpus](https://github.com/dask/fastparquet) | `f4beb59382e584354c4b2ef2c7a42efa4e97f024` | [Upstream Apache-2.0 license](tests/release/notices/FASTPARQUET-LICENSE) and [corpus notice](tests/release/notices/FASTPARQUET-NOTICE.md) |

NuMojo and mojo-snappy are Mojo source dependencies. GZIP and ZSTD use their
external native codec libraries through FFI. The Fastparquet corpus and Python
oracle packages are development/qualification inputs, not library execution
dependencies. Their exact versions are recorded in `tests/oracle-requirements.txt`.

The compiler and Mojo runtime are supplied separately by the pinned Pixi
packages and retain their upstream distribution terms and notices. This source
repository does not redistribute those package binaries.
