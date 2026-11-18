"""Compatibility: `morca.handover` moved to `morca._internal.handover` (#382).

Whether this run's code is outdated: `outdated()`, `outdated_why()`,
`code_version()` and `desired_code_version()` are public, and exported from
`morca`; import them from there. The rest of the module is internal, with
no stability promise.
"""

from morca._internal.handover import (
    code_version,
    desired_code_version,
    outdated,
    outdated_why,
)
