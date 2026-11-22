- **Working-set probe.** `learn = "working_set"` (with `probe_every = N`) in
  morca.toml lowers a probed local or control-placed run's `memory.high`
  against its memory pressure, records the working set beside the peak, and
  learns `auto` memory from it once 3 runs have one. (#588)
