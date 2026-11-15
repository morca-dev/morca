# The prebuilt `morca`

The morca-mojo package ships morca's own binaries, built once when the package
is, with the compiler it pins (#455):

| In the package | Built from | What it is |
|---|---|---|
| `bin/morca` | `bin/scheduler.mojo` | the scheduler, the UI, registration and the other commands (`morca.command`) |
| `bin/morca_maintain` | `bin/morca_maintain.mojo` | snapshot expiry and the UI's data reads (`morca.maintain`), which `morca` runs beside itself |
| `lib/liblake.so` (`.dylib`) | `src/morca/_lake/liblake.mojo` | the lake library `morca.tables` loads (#454) |
| `lib/mojo/morca.mojoc` | `src/morca` | the package pipelines and apps import |

A project therefore compiles only its own code: its pipelines and its apps.
Before, each project's `bin/scheduler.mojo`, two lines calling
`morca_command()`, compiled all of `morca._internal` (the scheduler, the
UI, the runners, the database layer), about half of the census's
`multicall-apps` binary, on every cold build and on every edit to anything
linked into the same binary.

## Using it

In a project's environment the package's `bin/` is on `PATH`, so `pixi run
morca ...` runs it:

```sh
pixi shelf add morca-mojo
mojo build pipelines/daily.mojo -o build/daily
pixi run morca locate build/daily --root . && pixi run morca register ./build/daily
```

In an image, the runtime (`ghcr.io/morca-dev/morca-runtime:<version>`,
`deploy/runtime.Dockerfile`) has the package's `morca` and `morca_maintain` at
`/opt/morca/bin`, so a project's image built `FROM` it
(`deploy/project.Dockerfile`) needs no `bin/scheduler.mojo`. An image built
another way copies them from its build environment:

```dockerfile
RUN env=/src/project/.pixi/envs/default && cp -L $env/bin/morca $env/bin/morca_maintain /out/bin/
```

The binaries are built with line tables (`-g1`), so a crash is symbolised
(`morca.crash`), and for a CPU every server of the platform has, as liblake
is: `x86-64-v3` on linux-64, `neoverse-n1` on linux-aarch64 (Hetzner's CAX
servers; it runs on Neoverse N2, V1, V2 and Graviton too) and `apple-m1` on
macOS. `MOJO_TARGET_CPU` applies to the project's own programs only.

A project can still build its own `morca` from `bin/scheduler.mojo`, the
same two lines, for instance to try a morca checkout's change or a build
with other flags. `deploy/project.Dockerfile` puts it in place of the
runtime's, as before.

## Versions

The binary and the pipelines it runs come from one morca-mojo:

- **One package.** `bin/morca` and `lib/mojo/morca.mojoc` are in the same conda
  package, so an environment can't hold a `morca` from one release and the
  `morca` package its pipelines import from another. That is the precedent
  liblake set: the same `mojo-compiler` pin, in the same package.
- **`morca version`** prints the morca-mojo it was built from
  (`morca._internal.version.MORCA_VERSION`, which `tests/version.sh` keeps
  equal to pixi.toml's and shelf.toml's version; CI's `version` job runs it
  on every pull request, release PRs too, and `sh tests/version.sh --fix`
  bumps it).
- **`describe`** says which morca a pipeline was built with, as its last key:
  `"morca": "0.33.0"`.
- **`morca register` refuses a pipeline of another morca**:

  ```text
  morca: /work/build/daily was built with morca 0.32.0 and this morca is 0.33.0:
  build the pipelines with, and run the `morca` of, one morca-mojo (the package
  ships `morca` in its bin/), or set MORCA_MIXED_VERSIONS=1 to register it anyway
  ```

  `MORCA_MIXED_VERSIONS=1` registers it with a warning instead. A pipeline
  built before describe said its morca (morca-mojo 0.32.0 and older) can't
  be checked, and registers as before. Runs aren't checked: a pipeline
  registered under one morca keeps running after the scheduler moves to the
  next, as it always has (an older binary on a newer schema, AGENTS.md).
- **The project image** (`deploy/project.Dockerfile`) stops when the runtime's
  `morca version` isn't the one in the project's environment, and says which
  `--build-arg MORCA_VERSION` to build with.

## Apps that extend morca

A project's app is a program of its own, not a plugin to `morca`. The
census's console is a flare server over the census tables: it imports
`morca.civil` and, through the census's `src/`, `morca.tables`, and nothing of
`morca.command` or `morca._internal`. It keeps compiling as it does today,
without morca's control plane in it, and runs beside the prebuilt `morca`
(`morca aws app`, the Hetzner stack's apps).

What a prebuilt `morca` can't take is code compiled into it: a project that
wants a command of its own inside `morca` (wrapping `morca_command()` with a
subcommand first, say) builds its own `morca` from `bin/scheduler.mojo` as
before, and pays for compiling morca. morca has no such extension point
today, so no project does this. If one is wanted, the cheap ways keep the
binary prebuilt: a separate program the project ships (as the console is),
or `morca` running another program for a command it doesn't know, as `git`
does with `git-<name>`.

## Multi-call binaries

The census links its programs into two multi-call binaries
(`scripts/multicall.sh` there), so the library code they share is compiled
and stored once. With the prebuilt `morca`, `bin/scheduler.mojo` leaves its
`multicall-apps`, which then holds the console alone, and
`bin/morca_maintain.mojo` leaves `multicall-pipelines`; `/opt/morca/bin/morca`
and `morca_maintain` are the package's files rather than links. Nothing the
pipelines share with `morca` is in the census build any more: they shared
morca's public modules, which a pipeline compiles anyway, and liblake, which
is a library.

## What it costs

Measured on sai (Ryzen Threadripper 1900X, 16 threads, `pixi build` of the
package for linux-64; ratios are what carry to other machines):

See the PR (#455) for the numbers: the package's build before and after,
and what a project's build skips.
