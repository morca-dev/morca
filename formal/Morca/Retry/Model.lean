import Morca.Core.Types

/-!
# A step's attempts and commits

One step of one run commits to one table, an attempt at a time. For each
commit the attempt looks through the table's snapshots for one it (or an
earlier attempt of the same step in the same run) already made, commits if
there is none, and records the snapshot in Postgres. Other writers commit to
the table in between, and the worker can crash between any two of these.

Mirrors src/morca/tables/__init__.mojo#find_commit+_found+_commit_append and
src/morca/ctx.mojo#Ctx.made+Ctx.summary+Ctx.committed+Ctx.commits_to.
-/
namespace Morca

/-- The environment: what an Iceberg commit, a Postgres write and a crash can
do. `Morca.Assumptions` says what the theorems assume of each. -/
structure Env where
  commit : Table → Summary → Table → Option Nat → Prop
  record : Ledger → Record → Ledger → Bool → Prop
  crash : State → State → Prop

/-- Whether a snapshot with summary `s` is step `me`'s commit number `n`,
made by any attempt: `Ctx.made`. -/
def made (me : StepId) (n : Nat) (s : Summary) : Bool :=
  decide (s.owner = me ∧ s.commit = n)

/-- The first snapshot that is `me`'s commit number `n`: `find_commit`. -/
def findCommit (me : StepId) (n : Nat) : Table → Option Nat
  | [] => none
  | x :: t => if made me n x.summary then some x.id else findCommit me n t

/-- How many snapshots are `me`'s commit number `n`. -/
def countMade (me : StepId) (n : Nat) : Table → Nat
  | [] => 0
  | x :: t => (if made me n x.summary then 1 else 0) + countMade me n t

/-- The state after a commit call that left table `t'` and returned `out`.
A failed call leaves the attempt about to commit: `_commit_append` tries
again without looking through the table a second time. -/
def afterCommit (s : State) (t' : Table) : Option Nat → State
  | some id => { s with table := t', phase := Phase.toRecord id }
  | none => { s with table := t' }

/-- The state after a Postgres write that left ledger `l'`. -/
def afterRecord (s : State) (l' : Ledger) : Bool → State
  | true => { s with ledger := l', done := s.done + 1, phase := Phase.looking }
  | false => { s with ledger := l' }

/-- One thing happening. In order: the attempt looks and finds its commit;
looks and finds none; calls Iceberg to commit; calls Postgres to record; the
worker crashes; another writer (any step, run or partition but this one)
commits a snapshot. -/
def Step (env : Env) (me : StepId) (s s' : State) : Prop :=
  (∃ id, s.phase = Phase.looking ∧ findCommit me s.done s.table = some id ∧
      s' = { s with phase := Phase.toRecord id })
  ∨ (s.phase = Phase.looking ∧ findCommit me s.done s.table = none ∧
      s' = { s with phase := Phase.willCommit })
  ∨ (∃ t' out, s.phase = Phase.willCommit ∧
      env.commit s.table (Summary.mk me s.attempt s.done) t' out ∧
      s' = afterCommit s t' out)
  ∨ (∃ id l' ok, s.phase = Phase.toRecord id ∧
      env.record s.ledger (Record.mk s.attempt s.done id) l' ok ∧
      s' = afterRecord s l' ok)
  ∨ env.crash s s'
  ∨ (∃ x : Snapshot, x.summary.owner ≠ me ∧
      s' = { s with table := s.table ++ [x] })

/-- Where a step starts: no snapshot in the table is its own (the run is
new), nothing is on record, and its first attempt is about to look. -/
structure Initial (me : StepId) (s : State) : Prop where
  fresh : ∀ x, x ∈ s.table → x.summary.owner ≠ me
  ledger : s.ledger = []
  done : s.done = 0
  phase : s.phase = Phase.looking

/-- The states a step can be in after any number of things happened. -/
inductive Reachable (env : Env) (me : StepId) : State → Prop where
  | init {s : State} : Initial me s → Reachable env me s
  | step {s s' : State} :
      Reachable env me s → Step env me s s' → Reachable env me s'

end Morca
