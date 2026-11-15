"""Compatibility: `morca.resources` moved to `morca._internal.resources` (#382).

This module keeps the public names it used to define importable from
here. Import them from `morca` instead; the rest of the module is
internal, with no stability promise.
"""

from morca._internal.resources import (
    Grant,
    auto_count,
)
