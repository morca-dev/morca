"""Utilities both `morca._internal` and `morca._lake` use, below them both:
nothing here imports from morca. `morca._internal` may import `morca._lake`,
never the other way round, so what the two share lives here.

- `dlopen`: finding and opening a shared library a tin ships.
- `paths`: paths made absolute.
"""
