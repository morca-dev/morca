"""`morca_main`: the command line every pipeline binary gets.

```mojo
def main() raises:
    morca_main[Sizes]()
```

`morca_main` and `report` are public (they're exported from `morca` too).
The command line itself, its subcommands and stores, is internal:
`morca._cli`.
"""

from morca._cli import morca_main, report
