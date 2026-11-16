"""The `morca` command: the scheduler, the UI and registration, in a binary
that links no pipeline. A project builds its own from two lines:

```mojo
from morca.command import morca_command

def main() raises:
    morca_command()
```

`morca_command` is public; the commands it runs are internal
(`morca._internal.command`), and their usage is `morca help`'s.
"""

from morca._internal.command import morca_command
