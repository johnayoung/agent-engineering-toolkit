# harness-promotion-gate

Decides whether a self-improving loop's candidate harness change may replace the incumbent, using evidence the loop did not write. It rejects a diff that touches the evaluator or anything it reads, applies the dual-split no-regression rule, checks every cited failure against an oracle-confirmed list, and prints PROMOTE, REJECT or FALLBACK with the evidence a named approver reads. It merges nothing.

## Usage

```bash
./harness-promotion-gate.sh \
  --git v12..candidate --protected example-protected.txt \
  --incumbent results/v12.tsv --candidate results/candidate.tsv \
  --cited change/cited.txt --confirmed oracle/confirmed.txt \
  --incumbent-tag v12 --approver @platform-lead --ledger gate-ledger.tsv

./harness-promotion-gate.sh stats gate-ledger.tsv   # accept and reject counts across rounds
```

The change comes from exactly one of `--git RANGE` (with `--repo DIR`), `--diff FILE` (unified diff, `-` for stdin) or `--paths FILE`. Run `--help` for every flag.

| Exit | Verdict | Live harness |
|---|---|---|
| 0 | PROMOTE: every check passed and a split improved | goes to the approver |
| 1 | REJECT: a check failed | stays on the incumbent |
| 3 | FALLBACK: clean, but no split improved | stays on the incumbent |
| 2 | input error (unaligned results, empty manifest, unparseable diff) | unchanged |

## Inputs

| File | Format | Who writes it |
|---|---|---|
| `--protected` | `<role> <glob>` per line; `*` crosses `/`, trailing `/` is a prefix | you, outside the editable surface |
| `--incumbent`, `--candidate` | `<split> <task_id> <pass\|fail>` per line; splits `proposer` and `gate` | the gate's own run, not the loop |
| `--cited` | one episode id per line | the change (its claim) |
| `--confirmed` | one episode id per line | an oracle replay outside the loop |

`example-protected.txt` covers the six roles the post freezes (the script warns when one is missing), the tracer and test dependencies the verifier reads, and the gate itself.

## Checks

- **protected.** Any changed path matching the manifest is a REJECT, whatever the scores say. Renames count both paths.
- **veto.** Each `--veto CMD` runs via bash from the repo; nonzero is a REJECT regardless of score. Use it for the security or policy check the score must not outvote.
- **episodes.** Zero cited episodes, or any cited episode missing from the confirmed list, is a REJECT. An add-only diff gets a note, since that is where phantom guards accumulate.
- **splits.** Self-Harness rule: improve at least one split, degrade neither, judged on pass counts. `--strict` also rejects any task the incumbent passed and the candidate fails (Henry Pan's discard rule). Per-task regressions and new passes are always listed.
- **release isolation.** A `release` row in the results is a REJECT. The release holdout is run by a person; the automated gate should never hold it.

## What it does not do

- Enforce the boundary. The manifest catches a protected edit after the fact; the edit itself should be blocked by file permissions or a supervisor check.
- Produce trustworthy results. It counts what you give it. Run the splits and the oracle replay from the gate's process, never from the change's summary of its own tests.
- Run the release holdout, tag versions, or roll back. PROMOTE says what to do before going live; a person does it.
- Judge a multi-candidate round. Run it per candidate; a round with no PROMOTE ends on the incumbent.

## Grounding

Canonical post: [Self-Improving AI Software Factory: Govern the Harness Loop](https://jyoung.dev/blog/self-improving-software-factory/)

- Acceptance rule: "A candidate is accepted only if it improves at least one split without degrading the other," and trade-off proposals "are rejected, even if their total pass count increases" ([Zhang et al.: Self-Harness](https://arxiv.org/abs/2606.09498)).
- `--strict` and the `stats` reference point: "768 of 1,231 non-baseline candidates were discarded because a baseline-solved task regressed" ([Henry Pan: 1,000+ Harness Experiments](https://www.henrypan.com/blog/2026-05-25-self-improvement-harness/)). One practitioner's setup, printed for context, not as a target rate.
- Protected roles: AHE keeps "the runs directory, tracer, verifier, and LLM configuration" read-only ([Lin et al.: Agentic Harness Engineering](https://arxiv.org/html/2604.25850v3)); a DO NOT CHANGE comment did not significantly change sandbox disabling ([Zelikman et al.: STOP](https://arxiv.org/abs/2310.02304)).
- Confirmed episodes and the add-only note: a warrant-aware rule that credits a guard only when an oracle confirms its cited failure kept phantom guards out ([Wang et al.: Phantom Guardrails](https://arxiv.org/abs/2607.13083)).
- Veto: "a mechanistically enforced veto that disregards benchmark scoring" ([Roesner, Kohno: Reflections on Trusting Trust, Revisited](https://arxiv.org/abs/2609.17817)).
- FALLBACK as a legal outcome: "if no candidate strictly improves, RSEA returns the empty state and reduces exactly to ReAct" ([Nguyen, Nguyen, Vuong: Held-Out Selection](https://arxiv.org/abs/2606.28374)).
- The release-only holdout and fallback-as-default are the author's judgment in the post, not a sourced design.
