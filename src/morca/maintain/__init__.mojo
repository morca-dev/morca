"""Table maintenance for a project's datasets: snapshot expiry.

The `morca` binary doesn't link iceberg, so expiry runs in a binary of the
project's own that does, `bin/morca_maintain.mojo`:

```mojo
from morca.maintain import maintain_main

def main() raises:
    maintain_main()
```

`maintain_main` is public; how expiry works is internal
(`morca._internal.maintain`).
"""

from morca._internal.maintain import maintain_main
