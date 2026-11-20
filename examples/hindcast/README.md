# Hindcast

How good were NOAA's weather forecasts? Hindcast fetches each day's GFS
forecast of 2 m temperature, 0 to 7 days ahead, and scores it against what
the next days' analyses say happened.

It's the showcase for [steps in Rust](../../docs/rust-workers.md): the
fetching and GRIB2 decoding are a Rust worker built from crates.io crates
(`grib`, `ureq` with rustls), loaded over the C ABI by `morca.rust_step`;
the scoring is ordinary Mojo steps over Iceberg tables.

```text
hindcast.mojo, partitions: forecast cycles (00z), Daily from 2021-03-23, 06:00 UTC for the day before

forecasts [mapped, Rust]                      skill [gather, Mojo]
  rust_step ──▶ libhindcast_worker              for each valid day V the run touches:
    per lead f000 … f168:                         analysis = f000 of cycle V
      GET gfs…f024.idx                            for each lead L: forecast of cycle V - L
      GET gfs…f024, Range: one message            bias, MAE, RMSE (cos-latitude weighted)
      decode (grib, template 5.3)                 and the city scorecard
      ──▶ one Arrow batch, 65,160 rows      ──▶ hindcast.skill, hindcast.cities
  ──▶ hindcast.t2m                                (replace V's partition)
      (replaces the cycle's partitions)
```

## What it does

- **Data.** GFS at 1° (`pgrb2.1p00`), the field `TMP:2 m above ground`, the
  00z run of each day, leads f000, f024 … f168. A file is 45 MB; the worker
  reads the file's `.idx`, finds the message (it ends where the next line's
  starts), and fetches only that with an HTTP Range request: about 74 KB a
  lead, from NOAA's open bucket
  `https://noaa-gfs-bdp-pds.s3.amazonaws.com/gfs.YYYYMMDD/00/atmos/gfs.t00z.pgrb2.1p00.fNNN`.
  No credentials.
- **`forecasts`**, the Rust step (src/lib.rs, src/gfs.rs). Each lead
  becomes one batch of (cycle, lead_hours, valid_time, lat, lon, t2m_k),
  made when morca pulls it, so the worker holds one lead at a time. The
  schema is schemas/t2m.json, which the worker embeds with `include_str!`
  and the proxy with scripts/embed-json.sh; `cargo test` checks the worker
  against it, and morca checks the stream against the table before writing.
  The library links only libc: `grib` without its C codecs (2 m temperature
  is complex packing, template 5.3, which `grib` decodes itself) and `ureq`
  over rustls with webpki's roots, so no OpenSSL and no CA files, which
  suits the distroless runtime image.
- **`skill`**, the Mojo step (skill.mojo). A forecast of cycle C at lead L
  is valid at V = C + L, and is scored against V's analysis, the f000 of
  cycle V: grid-wide bias, MAE and RMSE of forecast minus analysis, each
  point weighted by cos(latitude), and the error at the grid point nearest
  each of ten cities.
- **Tables**: `hindcast.t2m` (partitioned by cycle and lead),
  `hindcast.skill` (a row per cycle and lead) and `hindcast.cities` (a row
  per cycle, lead and city), both partitioned by valid date.

### Scores that need later days

A forecast can only be scored once its valid day's analysis is fetched: a
cycle's 7-day forecast waits a week. Hindcast handles that without
dependencies between partitions:

- A run's scoring step works out the valid days its cycles touch: each
  cycle's own day (its analysis scores the forecasts valid that day, from
  the seven cycles before) and the seven after (its forecasts, scored where
  those analyses are fetched already).
- For each such day V it recomputes everything valid at V from what
  `hindcast.t2m` has, and replaces V's partition in the score tables. A
  forecast whose analysis isn't there yet is skipped, and scored by the run
  that fetches the analysis.

So the scores don't depend on the order cycles arrive in. A daily run fetches
yesterday's cycle and scores the forecasts valid that day; a backfill's runs,
in any order or at once, end with every (cycle, lead) whose two cycles are
fetched; a rerun recomputes and replaces. A cycle is **complete** once all
seven leads are scored. `hindcast report` lists those that aren't yet.

A cycle that isn't in the bucket fails the worker with "not published yet".
For a cycle of the last two days the step then defers half an hour
(`morca.defer`), spending no retry; for an older one it fails.

## Running it locally

From the repository's root, in the `data` pixi environment; cargo runs in
the `rust` environment, which has the Rust toolchain and no Mojo
(scripts/cargo.sh):

```sh
pixi shell -e data
export CARGO_TARGET_DIR=$PWD/build/cargo
scripts/cargo.sh build --release --manifest-path examples/hindcast/Cargo.toml
mkdir -p build/hindcast
scripts/embed-json.sh examples/hindcast/schemas/t2m.json T2M_SCHEMA > build/hindcast/t2m_schema.mojo
scripts/mojo-build.sh -I src -I build/hindcast -I examples/hindcast $DEP_INC \
    examples/hindcast/hindcast.mojo -o build/hindcast/hindcast

export MORCA_WAREHOUSE=$PWD/build/hindcast/wh
export HINDCAST_LIB=$PWD/build/cargo/release/libhindcast_worker.so   # .dylib on macOS
./build/hindcast/hindcast run --partitions 2026-11-01..2026-11-12
./build/hindcast/hindcast report 2026-11-01
```

One run of twelve cycles fetches 96 messages (about 7 MB) and scores what
they allow: the first five cycles completely, the later ones as far as
2026-11-12's analysis goes.

- `HINDCAST_LIB`: the worker library; by default `hindcast_worker`, found as
  `libhindcast_worker.so` in `$CONDA_PREFIX/lib`, next to the binary or in
  its `../lib`.
- `HINDCAST_SOURCE`: where the files come from, a base URL or a directory
  laid out as the bucket; by default NOAA's bucket. The tests point it at
  fixtures/.
- `HINDCAST_LEADS`: the leads in hours, comma separated, whole days; by
  default `0,24,48,72,96,120,144,168`.

`hindcast report [cycle]` prints the skill per lead over the cycles scored
(mean bias and MAE, and the RMSE of them all), the cycles still waiting for
analyses, the tables' row counts, and with a cycle, that cycle's rows and
city scorecard.

## A 30-day backfill

Register the pipeline with a scheduler (which needs a database:
`MORCA_DATABASE_URL`, or scripts/with-postgres.sh for a throwaway one) and
backfill the days. The scheduler's runs inherit its environment, so set
`MORCA_WAREHOUSE` and `HINDCAST_LIB` where it runs:

```sh
pixi run morca    # builds ./build/morca
./build/morca register ./build/hindcast/hindcast
./build/morca backfill hindcast 2026-10-01..2026-10-30
./build/morca scheduler
./build/morca status hindcast
./build/hindcast/hindcast report
```

The backfill queues one run per day. Each run fetches its cycle (eight
Range requests) and rescores the valid days it touches, so the scores fill
in as runs finish, whatever order they finish in. Cycles to 2026-10-23 are
complete when the backfill is done; the last seven wait for analyses from
November, which the daily schedule (06:00 UTC, for the day before) or a
backfill of those days brings. `morca backfill --rerun hindcast <days>`
fetches and scores days again, replacing what was there.

## Tests

`pixi run -e data test-hindcast` (tests/hindcast.sh, in CI's `rust-worker`
job) runs offline, on fixtures/: the 2 m temperature messages of the
2026-11-12 and 2026-11-13 cycles at f000 and f024, each about 74 KB, cut
from NOAA's files, with `.idx` files of two lines whose offsets are those
in the cut file. It checks:

- the `.idx` lookup (`APTMP:2 m above ground` isn't `TMP`), and the fixtures
  decode to the 1° grid with the values ecCodes gives (`cargo test`);
- the library's exports, and that it links no Rust std or OpenSSL;
- the two cycles run in either order give the same scores;
- the grid-wide skill and the city scorecard against numbers ecCodes and
  numpy got (tools/skill_ref.py, run once by hand);
- a cycle waiting for its analyses is reported incomplete, a rerun
  replaces, and a missing cycle defers or fails by its age.

`cargo test --manifest-path examples/hindcast/Cargo.toml -- --ignored`
fetches f024 of 2026-11-12 from the live bucket and checks it's the
fixture.
