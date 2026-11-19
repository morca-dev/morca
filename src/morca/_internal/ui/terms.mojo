"""What the UI's words mean, in one place: the help on every table's column
headers, and on the values that come from a fixed set (statuses, step
kinds, triggers, placements, where a setting came from), so the same word
has the same explanation on every page.

```
header_help("Attempts")           # the "?" of a column named Attempts
header_help("From", "config")     # a column whose meaning depends on its table
value_help("status", "deferred")  # what a status chip says on hover
```

The UI (`morca._internal.web.page.respond`) adds a header's help to every `<th>` it
finds one for (a `data-help` attribute names a table-specific one), and
`Html.status` and `Html.term` put a value's on its chip or word. Texts are
HTML, written here as `if` chains (`_header`, `_context_header`, `_value`, `_key`), so
they may hold entities; none holds data from a request or a double quote,
as a value's goes in an attribute. An empty text means no help.
"""


comptime RUN_STATUSES: List[String] = [
    "queued",
    "running",
    "deferred",
    "succeeded",
    "failed",
    "cancelled",
]
"""The statuses a run takes (`orca.runs.status`), in the order a run goes
through them; a deferred run waits for its `retry_at`."""


comptime STEP_STATUSES: List[String] = [
    "pending",
    "running",
    "deferred",
    "succeeded",
    "failed",
    "skipped",
]
"""The statuses a step of a run takes (`orca.steps.status`)."""


comptime RUN_TRIGGERS: List[String] = [
    "schedule",
    "sensor",
    "backfill",
    "manual",
    "ui",
    "cli",
    "rerun",
    "rebuild",
    "fill",
]
"""The triggers morca writes (`orca.runs.trigger`): the scheduler's fires and
sensors, `backfill`, a binary's `run`, the UI's Start one run, `morca start`,
a rerun, a rebuild and a fill (`morca._internal.fill`). Runs `morca start`
queued before #378 have `ui`. The runs filter adds any others the table
has."""


comptime VOCABULARY_BEGIN = (
    "<!-- generated from morca._internal.ui.terms: pixi run docs-vocabulary -->"
)
"""Where docs/ui.md's generated tables start (`vocabulary_markdown`)."""
comptime VOCABULARY_END = "<!-- vocabulary: end -->"


def _md_table(
    mut out: String,
    kind: StaticString,
    head: StaticString,
    values: List[String],
):
    out.write("| ", head, " | Means |\n|---|---|\n")
    for v in values:
        out.write("| `", v, "` | ", value_help(kind, v), " |\n")


def vocabulary_markdown() -> String:
    """The run-status, step-status and trigger tables docs/ui.md has between
    `VOCABULARY_BEGIN` and `VOCABULARY_END`, from the texts here, so the
    docs use the words as the UI defines them (tests/test_terms.mojo checks
    they match)."""
    var out = String(VOCABULARY_BEGIN, "\n\n")
    _md_table(out, "status", "Run status", materialize[RUN_STATUSES]())
    out.write("\n")
    _md_table(out, "status", "Step status", materialize[STEP_STATUSES]())
    out.write("\n")
    _md_table(out, "trigger", "Trigger", materialize[RUN_TRIGGERS]())
    out.write("\n", VOCABULARY_END)
    return out^


comptime COVERAGE_HELP = (
    "How much of the pipeline is done: its days or months done of those in "
    "its range so far (its first partition through the last that has "
    "ended), or a keyed pipeline's keys done of the keys its dataset has. "
    "Done means every step succeeded in a run of code with the same steps' "
    "version=, as on the calendar; failed, skipped, queued and running "
    "ones aren't, nor ones done before a version= was raised. A dash "
    "means it has none to count yet."
)
"""The help of a pipeline's Coverage, in the home page's table and on its
Progress card."""


def _header(label: String) -> StaticString:
    """Each column header's help, by its label."""
    if label == "10 min":
        return "The host's CPU over its last ten minutes."
    if label == "Action":
        return "What was done: the path of the action posted."
    if label == "After":
        return (
            "The steps this one waits for: it starts once they have succeeded."
        )
    if label == "At":
        return "When it happened, in UTC."
    if label == "Attempts":
        return (
            "How many times the step ran in this run: more than 1 means an "
            "attempt failed and it was retried."
        )
    if label == "Busiest core":
        return "The busiest single core's use at its highest."
    if label == "By":
        return "The user who did it, as they logged in."
    if label == "By run":
        return "The run that committed its latest snapshot."
    if label == "Checks":
        return "What the rule checks, each threshold with the last value seen."
    if label == "Commit":
        return "The git commit the binary was built from."
    if label == "Committed":
        return "When the attempt that wrote it finished."
    if label == "Container":
        return "A Docker container on the control host."
    if label == "Code":
        return (
            "The code hash: what the binary says about itself (its steps, "
            "partitions and schedule). It changes when they do, not on "
            "every build."
        )
    if label == "CPU":
        return (
            "CPU used: for a step, its latest attempt's user and system "
            "seconds; for a machine, its busiest moment as a share of all "
            "cores."
        )
    if label == "CPUs":
        return "The worker's cores, from its last heartbeat."
    if label == "Coverage":
        return COVERAGE_HELP
    if label == "Created":
        return "When it was made: a run when it was queued."
    if label == "Dataset":
        return "A table in the warehouse that pipelines read or write."
    if label == "Disk":
        return "The fullest disk the run writes to, at its fullest."
    if label == "Disk io":
        return "Disk reads and writes, at their highest rate."
    if label == "Ended":
        return "When it finished, whatever the outcome."
    if label == "Error":
        return "Why it failed, as the step or morca said."
    if label == "Expires":
        return "When the token stops working."
    if label == "Fills":
        return "The partition that run fills."
    if label == "First seen":
        return "When a run first ran this version."
    if label == "From":
        return "Where it came from."
    if label == "Host":
        return "The instance: its role (head or worker) and its id."
    if label == "Image":
        return "The container image the code ran in, if any."
    if label == "Instance":
        return (
            "Where the samples were taken: local (the scheduler's machine), "
            "control, an EC2 head or worker, or a pod."
        )
    if label == "Key":
        return (
            "The setting's name, as morca.toml and morca register's flags "
            "call it."
        )
    if label == "Kind":
        return (
            "How the step runs: mapped, once per partition, or gather, once "
            "over all of them. Hover a kind for more."
        )
    if label == "Label":
        return "The name the token was given when it was made."
    if label == "Last run":
        return "Its latest run, and how it went."
    if label == "Last seen":
        return "The last time it was seen."
    if label == "Latest":
        return "Its newest snapshot that a morca run committed."
    if label == "Launched":
        return "When EC2 started the instance."
    if label == "Level":
        return (
            "How far downstream of the dataset: level 1 reads it, level 2 "
            "reads what level 1 writes, and so on. A level starts once the "
            "one before is done."
        )
    if label == "Log":
        return "Its output: an attempt's, an instance's or the run's process's."
    if label == "Memory":
        return "Memory used at its highest, of the machine's total."
    if label == "Memory now":
        return "The container's memory now, as docker stats counts it."
    if label == "Message":
        return "What the alert said."
    if label == "Net in / out MB/s":
        return "The host's network traffic in and out, in MB a second."
    if label == "Network":
        return "Network traffic in and out, at its highest rate."
    if label == "Next run":
        return "When the schedule fires next, in UTC."
    if label == "Partition":
        return (
            "The partition this row is for; empty for a gather step, which "
            "runs once over all of them."
        )
    if label == "Partitions":
        return (
            "The partitions it covers: months, days, hours or named keys. "
            "Each step runs once per partition."
        )
    if label == "Peak":
        return (
            "The most memory the step's latest attempt held at once; its "
            "page has each attempt's."
        )
    if label == "Peak in range":
        return "The most memory the container held over the range shown."
    if label == "Pipeline":
        return (
            "A pipeline: a binary of steps, registered with morca, that runs "
            "on its schedule or when asked."
        )
    if label == "Pipelines":
        return "The pipelines the rebuild runs, and their runs."
    if label == "Pool":
        return (
            "The worker pool: a pipeline placed worker:&lt;pool&gt; runs on "
            "that pool's workers."
        )
    if label == "Priority":
        return "The alert's priority on the phone: high, default or low."
    if label == "Queued":
        return "Runs waiting to start."
    if label == "Read":
        return (
            "The snapshots the step read when it wrote this one. Click one "
            "for its own lineage."
        )
    if label == "Read by":
        return "The pipelines, and their steps, that read it."
    if label == "Read or wrote":
        return (
            "read: the step read this snapshot. wrote: it committed it, a "
            "new snapshot of the table."
        )
    if label == "Reads":
        return "The datasets the step reads."
    if label == "Rebuild":
        return (
            "A rebuild: the pipelines downstream of a dataset run again "
            "over some partitions, level by level."
        )
    if label == "Role":
        return (
            "head: the run's driver and dista head. worker: a dista worker "
            "its tasks fan out to."
        )
    if label == "Rule":
        return "A watchdog rule, and what it pauses when it trips."
    if label == "Run":
        return (
            "A run: one start of a pipeline over some partitions, with its "
            "steps and their attempts. Click for its page."
        )
    if label == "Running":
        return "Runs going now."
    if label == "Runs":
        return "How many runs used it."
    if label == "Samples":
        return "How many samples the sampler took."
    if label == "Schedule":
        return "When it runs: a cron expression, or none for runs on demand."
    if label == "Seen":
        return "When its sensor saw the snapshot."
    if label == "Snapshot":
        return (
            "A snapshot of a table: the table as one commit left it. Click "
            "for its lineage."
        )
    if label == "Snapshots":
        return "How many snapshots morca runs have committed to it."
    if label == "Snooze":
        return "Silence the rule for a while: its trips don't pause."
    if label == "Start":
        return (
            "Which start of the run's process it served: 1, or more after a "
            "retry or a resume."
        )
    if label == "Started":
        return "When it started; empty while it waits."
    if label == "State":
        return "Where it stands now."
    if label == "Status":
        return "Where it stands. Hover a status for what it means."
    if label == "Steal":
        return "CPU time the hypervisor gave to other machines."
    if label == "Step":
        return (
            "A step of the pipeline: a function that runs once per "
            "partition (mapped) or once over all of them (gather)."
        )
    if label == "Subject":
        return "What the alert is about: a run, a pipeline, a worker or a host."
    if label == "Table":
        return "The table's name in the warehouse."
    if label == "Token":
        return (
            "A worker token: how a remote worker signs in, and which pool's "
            "runs it may claim."
        )
    if label == "Took":
        return "How long the run took, from its start to its end, or so far."
    if label == "Trigger":
        return "What started the run. Hover a trigger for what it means."
    if label == "Tries":
        return (
            "Times the run's process was started: 1 is normal; more means "
            "retries, a lost instance or a resume."
        )
    if label == "Type":
        return "The EC2 instance type."
    if label == "Uptime":
        return "How long the instance has been up."
    if label == "UTC":
        return "When the schedule fires, in UTC."
    if label == "Value":
        return "The value it is registered with."
    if label == "Wall clock":
        return "The same moment in the pipeline's time zone."
    if label == "Warnings":
        return (
            "Stretches with memory or a disk over 90%, or CPU steal over "
            "20%: what slows or fails most runs."
        )
    if label == "When":
        return "When it happened."
    if label == "Why":
        return "Why it happened, as morca recorded it."
    if label == "Worker":
        return "The worker using the token: its host name."
    if label == "Writes":
        return "The datasets the step commits to."
    if label == "Written by":
        return "The pipeline, and its step, that wrote it."
    return ""


def _context_header(key: String) -> StaticString:
    """Headers whose meaning depends on their table: `<table>:<label>`, the
    table named by the header's `data-help`."""
    if key == "config:From":
        return (
            "Where the value came from: the code's default, morca.toml (and "
            "which table), a flag of morca register, or the scheduler's "
            "environment. A link opens the line that sets it."
        )
    if key == "audit:From":
        return "ui: this site. cli: the morca command, with a token."
    if key == "alerts:Kind":
        return (
            "What raised the alert: a watchdog trip, a run that failed with "
            "no retry left, a stalled fill, the control disk filling, a "
            "worker gone quiet, memory pressure holding runs, a failed "
            "backup or another script's morca notify; 'resolved' is the "
            "all-clear sent once it ended. Its priority is on hover."
        )
    if key == "alerts:When":
        return "When the alert was raised, or resolved; the full time on hover."
    if key == "alerts:Alert":
        return "The title and the message, as they were sent to the phone."
    if key == "alerts:Links":
        return (
            "What the alert is about: its run, the pipelines it paused or "
            "names, the watchdog's rule, the worker, or Control."
        )
    if key == "alerts:Delivered":
        return (
            "Whether ntfy took it: sent; waiting for its first try; failed, "
            "retrying (the error, tried again after a wait that doubles up "
            "to 15 minutes); or not sent, when a newer one or its "
            "resolution replaced it first."
        )
    if key == "alerts:State":
        return (
            "For alerts that end (a watchdog trip, a stalled fill, the disk, "
            "memory pressure): open while it still holds, resolved once it "
            "ended, or raised again when the same alert was sent anew "
            "before that. Empty for one that doesn't end, such as a run "
            "failed."
        )
    if key == "alerts:Status":
        return "sent, pending (it will be tried again) or resolved."
    if key == "instances:Why":
        return (
            "Why the instance ended: drained when idle, pooled for the next "
            "run, or lost."
        )
    if key == "sensed:Why":
        return (
            "Why the snapshot's keys weren't run: they aren't this "
            "pipeline's partitions."
        )
    # Ops' Pools (morca.ui.pools): a row per machine, the worker in its row.
    if key == "pools:Machine":
        return (
            "The machine: an EC2 instance's id, a Kubernetes run's pods, or "
            "the host name a self-hosted worker gave (its token's label until "
            "it has claimed). Click for its page."
        )
    if key == "pools:Pool":
        return (
            "Where a placement sends runs: ec2 (instances morca launches), "
            "kubernetes (a run's pods) or worker:&lt;pool&gt; (the machines "
            "running morca worker for that pool). Click to show only it."
        )
    if key == "pools:Kind":
        return (
            "ec2: an instance morca launched and pays for. k8s: a run's pods "
            "on the cluster. self-hosted: a machine of your own running morca "
            "worker."
        )
    if key == "pools:State":
        return (
            "live: up and taking work. draining: the scheduler is letting it "
            "finish before it goes. gone: an instance that ended (listed for "
            "an hour), or a worker revoked, expired or not heard from for "
            "MORCA_STALE_SECONDS. Beside it, what it is doing."
        )
    if key == "pools:Image":
        return (
            "The image tag its runs need: the pipeline's image on EC2 and "
            "Kubernetes, the worker's MORCA_IMAGE as it said."
        )
    if key == "pools:CPUs":
        return (
            "Its vCPUs: the instance type's (or its sampler's count), the "
            "CPU a run's pods asked for, or the cores the worker said it has."
        )
    if key == "pools:Memory":
        return (
            "Its memory: the instance type's, or what the worker said it has."
        )
    if key == "pools:Runs":
        return "The runs on it now. Click one for its page."
    if key == "pools:Last heartbeat":
        return (
            "When it was last heard from: an instance's last sample, a "
            "worker's last claim, a run's pods' last heartbeat."
        )
    if key == "pools:CPU":
        return (
            "Its CPU in use at the last sample, and over the last ten "
            "minutes. Only EC2 instances are sampled for Ops."
        )
    if key == "pools:Worker":
        return (
            "What morca runs there: a run's head or a dista worker on EC2; "
            "morca worker, signed in with the token named (hover for when it "
            "expires); or a run's pods."
        )
    if key == "pools:Uptime":
        return "How long since it launched (a pod: since its run started)."
    if key == "pools:Expires":
        return "When the worker's token stops working."
    if key == "pools:Ended":
        return "When the instance ended, and why."
    if key == "config:Key":
        return (
            "The setting's name, as morca.toml and morca register's flags "
            "call it. Hover the name for what it sets."
        )
    return ""


def _value(key: String) -> StaticString:
    """Each value's help, by `<kind>:<value>`."""
    if key == "machine:live":
        return "Up, and taking work or doing it."
    if key == "machine:draining":
        return "The scheduler is letting it finish its work before it goes."
    if key == "machine:gone":
        return (
            "Ended (an instance), or no longer heard from (a worker: revoked, "
            "expired or quiet)."
        )
    if key == "machine_kind:ec2":
        return "An EC2 instance morca launched for a run, and pays for."
    if key == "machine_kind:k8s":
        return "A run's pods on the Kubernetes runner's cluster."
    if key == "machine_kind:self-hosted":
        return "A machine of your own, running morca worker for its pool."
    if key == "status:queued":
        return "Waiting to start: its turn, or room for its placement."
    if key == "status:running":
        return "Going now."
    if key == "status:deferred":
        return "A step asked to run again later; the run waits until then."
    if key == "status:succeeded":
        return "Done, every step succeeded."
    if key == "status:failed":
        return (
            "Something failed after its last retry. Resume runs what hadn't "
            "succeeded."
        )
    if key == "status:cancelled":
        return "Stopped on request, before its next attempt."
    if key == "status:skipped":
        return "Not run: a step it waits for didn't succeed."
    if key == "status:pending":
        return "Not started yet in this run."
    if key == "status:paused":
        return "The scheduler starts none of its runs until unpaused."
    if key == "status:done":
        return "A run has done this partition."
    if key == "status:not done":
        return "No run has done this key yet."
    if key == "status:open":
        return "Not reached yet."
    if key == "status:live":
        return "A run of it is going now."
    if key == "status:stalled":
        return "Its process stopped sending heartbeats."
    if key == "kind:mapped":
        return "Runs once per partition, each on its own."
    if key == "kind:gather":
        return "Runs once, over what every partition of the step before made."
    if key == "trigger:schedule":
        return "Its schedule fired."
    if key == "trigger:sensor":
        return "Its sensor saw a new snapshot of a table it reads."
    if key == "trigger:backfill":
        return (
            "morca backfill, or a Backfill button here: Start runs' or a runs"
            " list's Backfill again."
        )
    if key == "trigger:manual":
        return "A binary's run command started it, outside the scheduler."
    if key == "trigger:ui":
        return "Start runs' Start one run over the whole range, on this site."
    if key == "trigger:cli":
        return "morca start: one run over the partitions it was given."
    if key == "trigger:rerun":
        return "A rerun of an ended run, from a step on."
    if key == "trigger:rebuild":
        return "A rebuild of everything downstream of a dataset."
    if key == "trigger:fill":
        return "The fill: the scheduler working through the range by itself."
    if key == "placement:default":
        return (
            "On the scheduler's runner (MORCA_RUNNER: local, kubernetes or"
            " ec2)."
        )
    if key == "placement:local":
        return "Beside the scheduler, on its machine."
    if key == "placement:control":
        return (
            "On the control host, beside Postgres and the scheduler, within "
            "its limits."
        )
    if key == "placement:ec2":
        return "On EC2 instances of its own, a head and workers."
    if key == "placement:kubernetes":
        return "In pods on the Kubernetes cluster."
    if key == "placement:worker":
        return "On a remote worker of that pool, which claims the run."
    if key == "from:code default":
        return (
            "Nothing set it: the pipeline's code, or morca, has this default."
        )
    if key == "from:morca.toml":
        return "Set in morca.toml, in the table shown."
    if key == "from:flag":
        return "Set by a flag of morca register, over morca.toml."
    if key == "from:environment":
        return "Taken from the scheduler's environment when the run starts."
    if key == "touch:read":
        return "The step read this snapshot."
    if key == "touch:wrote":
        return "The step committed this snapshot."
    if key == "fills:all":
        return (
            "The scheduler fills the whole range by itself, a run per "
            "partition, within its budget and window."
        )
    if key == "fills:since_registration":
        return (
            "A schedule fills from registration on; earlier partitions need "
            "a backfill."
        )
    if key == "fill_order:oldest":
        return "Fill runs go from the oldest partition forward."
    if key == "fill_order:newest":
        return "Fill runs go from the newest partition back."
    if key == "spot:true":
        return (
            "Its EC2 instances are Spot: cheaper, and AWS can take them back."
        )
    if key == "spot:false":
        return "On-demand EC2 instances."
    if key == "role:head":
        return "The run's driver and dista head."
    if key == "role:worker":
        return "A dista worker the run's tasks fan out to."
    return ""


def _key(key: String) -> StaticString:
    """Each setting's help, by its key (`secrets.X` and `env.X` by their
    table)."""
    if key == "placement":
        return (
            "Where its runs start: default (the scheduler's runner), "
            "control, ec2, or worker:&lt;pool&gt;."
        )
    if key == "head_type":
        return "The EC2 instance type of a run's dista head."
    if key == "worker_type":
        return "The EC2 instance type of each dista worker."
    if key == "workers":
        return (
            "How many dista workers a run asks for, or min..max to scale "
            "between."
        )
    if key == "worker_procs":
        return (
            "Dista worker processes on each worker instance; auto for one "
            "per core."
        )
    if key == "max_runs":
        return "The most runs of the pipeline the scheduler starts at once."
    if key == "fills":
        return (
            "all: the scheduler fills the whole range by itself. "
            "since_registration: from registration on."
        )
    if key == "fill_order":
        return "Which end of the range the fill starts from."
    if key == "fill_max_runs":
        return "Fill runs at once, on top of max_runs."
    if key == "fill_budget_per_day":
        return "The most the fill may spend a day, in dollars."
    if key == "fill_window":
        return "The hours of the day, UTC, in which fill runs start."
    if key == "fill_lag":
        return "How long after its end a partition is filled."
    if key == "priority":
        return (
            "Higher starts first when room is short: the scheduler takes the "
            "pipelines highest first, then by name."
        )
    if key == "concurrency":
        return (
            "A key its runs hold while they run, shared with every pipeline "
            "that declares it: at most limit of them run at once, across "
            "every scheduler and worker."
        )
    if key == "image":
        return "The container image its runs use."
    if key == "spot":
        return "Whether its EC2 instances are Spot."
    if key == "secrets":
        return (
            "A secret put in its runs' environment, by its id in the secret "
            "store; its value is never shown."
        )
    if key == "env":
        return "A variable set in its runs' environment."
    return ""


def key_help(key: StringSpan) -> StaticString:
    """The help of a setting `key` of morca.toml (`env.NAME` is `env`'s)."""
    var k = String(key)
    var dot = k.find(".").or_else(-1)
    if dot > 0:
        var head = String(k[byte=:dot])
        k = head^
    return _key(k)


def header_help(label: StringSpan, table: StringSpan = "") -> StaticString:
    """The help of a column named `label`, in `table` if it has its own."""
    if table:
        var t = _context_header(String(table, ":", label))
        if t:
            return t
    return _header(String(label))


def value_help(kind: StringSpan, value: StringSpan) -> StaticString:
    """The help of `value` of `kind` (`status`, `kind`, `trigger`,
    `placement`, `from`, `touch`, `role`, `fills`, `fill_order`, `spot`):
    a placement `worker:<pool>` is `worker`'s."""
    var v = String(value)
    if kind == "placement" and v.startswith("worker:"):
        v = "worker"
    return _value(String(kind, ":", v))
