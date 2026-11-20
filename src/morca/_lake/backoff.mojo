"""How long a commit that clashed with another writer's waits before it
reloads and tries again."""

from std.time import sleep

from iceberg.util import random_long


def backoff(attempt: Int):
    """Waits before retry `attempt` (1, 2, ...) of a commit that clashed:
    10 ms doubling with each, to 640 ms, times `jitter()`. Writers that
    claim the same metadata version at once all back out (iceberg's
    filesystem catalog), so retrying at once can clash again and again; the
    random wait lets one get ahead.
    """
    var base = 0.01 * Float64(1 << min(attempt - 1, 6))
    sleep(base * jitter())


def jitter() -> Float64:
    """A random factor from a half to one and a half, drawn from the OS
    (iceberg's `random_long`, from /dev/urandom), not from `std.random`.

    `std.random` gave every process the same waits unless something had
    seeded it: only `morca_main` does (`morca._cli.seed_random`), so writers
    in programs that make their own `Ctx`, as the iceberg-rust spike's Mojo
    side does, backed off in lockstep, clashed again on every retry, and ran
    out of retries (#532).
    """
    return 0.5 + Float64(random_long() % 1_000_000) / 1_000_000.0
