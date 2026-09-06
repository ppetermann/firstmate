# Review memory in a project's AGENTS.md

A project can carry a short section of review memory in its committed `AGENTS.md`: the
classes of defect its reviews keep finding, kept so the next implementer and the next
review round both start where the last one finished. This file owns how that section is
named, shaped, and retired. The mechanism that writes it is owned by `ocr-bot-review`.

## Name it for what a reader does with it

The section is headed exactly:

```
## Ask these of every change
```

Not "Known defects", not "Known defect classes", not "Common bugs". Every entry in it is a
question a reviewer or implementer asks of a diff. Naming the section after the
archaeology that produced the entries describes how they were found, which no reader
needs, and invites two misreadings that are worse than the wasted words: that the project
currently contains those defects, and that the section is a register to log incidents in.
It is neither. It is a list of questions no test asks yet.

The same rule governs any later section of this kind: name it for the use, in the
imperative, so the heading itself tells a reader what to do with what follows.

## Every entry is a question first

The `Ask:` clause is the entry. The class name, the date, and the instance links are
context that makes the question credible; they are not the content. Write the question as
a positive test a reader can run against a diff ("for every gate on X, what does the code
after it read?"), never as a list of things not to do.

Keep the shape uniform so the section stays scannable:

```
- **<short class name>** (since <YYYY-MM-DD>; instances: <links>): <the predicate, shape
  and condition that produce it, one sentence>. Ask: <the positive test, one sentence>.
  Guard: <the test or lint that now catches it, or `none yet`>.
```

## An entry dies when a machine can ask it

`Guard:` is the exit condition, not decoration. Once a test or lint asks the question on
every run, the entry has been promoted out of prose and is deleted — deleted, not struck
through, not moved to a history subsection. An entry whose guard exists but which is still
present is itself a documentation defect.

An entry also dies of disuse: ten merged pull requests on that repository with no new
instance retires it.

## Cap it, because every session pays for it

At most eight entries, each at most four lines. This text is loaded by every agent session
in that project, not only by review rounds. A worker adding a ninth entry retires one
first and names it in the commit.

## One copy

When an entry states a rule that prose elsewhere in `AGENTS.md` already states, the prose
moves into the entry in the same change. Two statements of one rule drift, and the review
round that finds the drift is a round spent on our own documentation.

## It is memory, not a register

No blame, no incident narrative, no fix log, no "fixed in #N" bookkeeping. The instance
links carry all the history the question needs. A section that has become a place to
record what went wrong has stopped being read, and an entry cited as a reason to skip a
fix rather than to write one is an entry to retire.
