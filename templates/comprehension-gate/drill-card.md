# Drill card

<!-- comprehension-gate drill. One card per agent-written path. Build the scenario and the
     "Must find" list from the path's merged comprehension block. -->

Target:
Owner:
Last drill:
Next drill:
Players:
Game master:
Rules:        no agent, no chat assistant; the PR's comprehension block, code, logs, and dashboards allowed

<!-- Target:      PR or commit, plus the path (e.g. "PR 812, internal/payments/webhook").
     Next drill:  YYYY-MM-DD. First drill about three weeks after merge, then once a quarter.
                  Backlog tickets from this card are due before this date.
     Players:     "primary = <owner>; secondary = <next on-call on the same rotation>".
     Game master: someone who knows the path and is not playing, e.g. the tech lead. -->

## Scenario

<!-- The failure as it unfolds, then the page text exactly as on-call would receive it.
     Base it on a failure mode from the comprehension block or a past incident on this path. -->

## Must find

<!-- One numbered line per item the players must reach unaided. Cover at least the debug
     path, one invariant, and one failure mode. Make one item the one built to fail: the
     thing an owner who remembers only a name would get wrong (a kill switch that only
     half-works, say). The game master marks each line [found] or [missed] during the drill.
     A line still at [ ] when the drill ends counts as unanswered. -->

1. [ ]
2. [ ]
3. [ ]

## Game-master steps

1. Before the drill, reread the path's comprehension block and the code as it is today. Agent sessions may have changed it since merge; that drift is part of what the drill tests.
2. Write the scenario and the "Must find" list. Realism matters more than difficulty.
3. Confirm the players: primary is the owner, secondary is the next on-call on the same rotation. The prompter plays only if they are on that rotation.
4. Open the drill by restating the rules. No agent and no chat assistant, for anyone.
5. Read the page aloud. Reveal system state only when a player asks for something concrete (a query, a trace, a log search) and answer with what that would actually show.
6. Do not hint. An item reached only after a hint is `[missed]`.
7. Mark each item `[found]` or `[missed]` as it happens. Leave nothing at `[ ]` unless the drill ran out of time, and know that `[ ]` is scored as unanswered.
8. Afterwards run `./drill-backlog.sh <this card>`. Every missed or unanswered item becomes a ticket labelled `comprehension-debt`, assigned to the owner, due before the next drill. If the drill showed the comprehension block itself is wrong, the owner's first ticket is to correct it.

## Notes

<!-- Game master's notes: what the players tried, where they stalled, what the block got wrong. -->
