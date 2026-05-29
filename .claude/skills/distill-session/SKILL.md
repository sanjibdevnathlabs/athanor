---
name: distill-session
description: Methodology document for distilling a session transcript into structured KB artifacts. Reference for the session-distiller agent. Defines extraction rules, granularity bounds, and quality gates. Domain-adaptive — works for any kind of session.
---

# distill-session

The methodology behind the session-distiller agent. Read this if modifying the agent's prompt.

The distiller is a **universal second brain**: it extracts durable knowledge from ANY session — software debugging, research, product discussions, data analysis, writing, oncall — without being told the domain. It reads the transcript and decides what's worth keeping.

## Inputs

- Transcript file: `.athanor/raw/<date>-<session>.jsonl`
- Session id

## Universal entity model

Everything maps to one of five topic-agnostic types. There is no domain-specific type.

| Type | What to capture |
|---|---|
| `Concept` | Any named thing worth knowing: tool, service, person, library, technology, feature, system, organization, or a term used in a specific way. |
| `Finding` | Something discovered or concluded: bug, insight, root cause, hypothesis, anomaly, risk. Requires a `summary`. |
| `Procedure` | Repeatable steps: runbook, workflow, debugging process, setup/config recipe. |
| `Pattern` | A recurring structure: design pattern, failure mode, anti-pattern, methodology, behavioural pattern. |
| `Session` | One per session: what was worked on, the outcome, the domain. |

## Step 0: detect the domain

Before extracting anything, read the transcript and set a free-form `domain` tag (no closed vocabulary). It goes on every entity from this session. Infer it from what the session is about:

| Session content | `domain` |
|---|---|
| Debugging a prod issue from logs/metrics/traces | `software-engineering/oncall` |
| Pair programming, writing/refactoring code | `software-engineering/development` |
| Reviewing a research paper, comparing approaches | `research` |
| Writing a product spec, scoping a feature | `product-management` |
| Querying data, building charts, drawing conclusions | `data-analysis` |
| Drafting docs or communications | `writing` |

Pick the single best-fit label. Spanning two areas → choose the dominant one.

## Extraction targets

For every candidate, ask: *would a future session benefit from knowing this?* No → drop it.

### 1. Concept entities
Named things central to the session. A service, tool, library, person, team, organization, feature, or a term defined/used in a specific way. Skip things mentioned once in passing that don't matter to the outcome. Wrapper handles dedup against the graph.

### 2. Finding entities
Conclusions, discoveries, observations. **Requires `summary`** (10–500 chars, factual, present-tense, grounded in transcript — no speculation beyond what was stated). A hypothesis is a valid Finding, but mark it as a hypothesis in the summary; do not inflate to fact.

`canonical_name` is a short lowercase-hyphenated slug, e.g. `cache-key-collision-root-cause`, `apollo-batching-insight`.

### 3. Procedure entities
A repeatable process that emerged. The steps to resolve a problem, a workflow that worked, a debugging or setup process. Optional `outcome` field {`resolved`, `mitigated`, `open`, `abandoned`, `completed`, `partial`} when the procedure was applied to a problem this session. A Procedure does NOT require a written file — the entity + observations suffice. Write a file (step 8 of the agent) only when the steps are detailed enough to follow verbatim later.

### 4. Pattern entities
A recurring structure noticed across this or prior work: a failure mode, design/architectural pattern, anti-pattern, methodology, or behavioural pattern. Only emit when the recurrence is real or explicitly named — not for one-off observations (those are Findings).

### 5. Session entity
Exactly one per session. **Required fields** (wrapper rejects if missing):
- `session_id` — same as `KB_SESSION_ID`
- `occurred_at` — ISO-8601 UTC when the work started, from the transcript (e.g. first message timestamp, or an explicit time in content)
- `outcome` — one of {`resolved`, `mitigated`, `open`, `abandoned`, `completed`, `partial`}, by what literally happened:
  - `resolved` or `completed`: session goal fully achieved. Prefer `completed` for non-problem-solving sessions (writing, research); prefer `resolved` for oncall/debugging where a fix was confirmed.
  - `mitigated` or `partial`: partially addressed. Use `partial` for exploratory or creative sessions where "mitigated" doesn't apply (e.g. wrote half a doc, read some papers). Do NOT inflate to `resolved`/`completed`.
  - `open`: incomplete, still active
  - `abandoned`: stopped without meaningful progress
- `summary` — what was worked on and the result (10–500 chars)

If the user says "mitigated" or "pending root cause", DO NOT inflate to `resolved`/`completed` even if a symptom went away.

## Relations to extract

Twelve LOCKED predicates (`protocol/vocabulary/relations.txt`). The tuple `(subject_type, predicate, object_type)` must match `protocol/schema/relation-types.json`. Common shapes:

- `Finding` / `Pattern` —`OBSERVED_IN`→ `Session` (discovery/pattern surfaced this session)
- `Finding` —`RESOLVED_BY`→ `Procedure` (steps that fixed it)
- `Procedure` / `Concept` —`ADDRESSES`→ `Finding` / `Concept`
- `Finding` / `Concept` —`INSTANCE_OF`→ `Pattern` (an instance of a recurring pattern)
- any —`RELATED_TO`→ any (two things meaningfully co-discussed)
- any —`REFERENCES`→ any (general reference)
- any —`CORRECTED_IN`→ `Session` (something corrected this session)
- `Finding`/`Procedure`/`Pattern` —`SUPERSEDES`→ older `Finding`/`Procedure`/`Pattern`
- `Finding`/`Procedure`/`Pattern` —`DISPUTED_BY`→ `Session` / `Concept`
- any —`CAUSES`→ any (subject directly causes object: event causes symptom, action causes outcome)
- any —`DEPENDS_ON`→ any (subject requires object: step requires prior step, feature requires library)
- any —`ALTERNATIVE_TO`→ any (subject is an option alongside object: approach A vs approach B)

Forbidden:
- Speculative relations ("might be related to")
- Future-tense relations ("will probably resolve")
- Relations without grounding in transcript

## Observations (per-entity facts)

Each observation must include `evidence_snippet` (≥20 chars verbatim from transcript). Wrapper rejects shorter.

Cap: ≤5 observations per entity per session.

Emit an observation for each concrete finding/step/value worth recording:
- A remediation or action step taken → observation on the relevant Procedure or Finding
- A concrete metric, threshold, or result reached → observation on the relevant Finding/Concept
- An explicit user capture statement (`remember: ...`, `note that: ...`) → observation on the entity it describes
- An attribution (`X caused Y`) → observation on the Finding

## User correction handling

Detect via tokens: "no", "wrong", "actually", "don't", "incorrect", "that's not right".

For each correction:
1. Identify which prior assistant action / entity it corrects
2. Increment `corrections` counter on the relevant ledger slot (`entities`, `procedures`, or `patterns`)
3. Demote tier by one (autonomous→tested, tested→unverified)
4. Stage a `CORRECTED_IN` relation (corrected entity → Session) so the graph records it
5. Write a `feedback`-type memory entry under `.athanor/memory/feedback-<topic>.md` with the verbatim correction + Why + How to apply

## Granularity rules

- **Too coarse** (rejected): "Investigated an issue"
- **Too fine** (rejected): one observation per tool call
- **Right** (accepted): "p99 spike correlated with deploy v2.4.7; rollback at 14:48 normalised by 14:50" (oncall) / "Apollo `@defer` reduced TTFB by batching field resolvers; confirmed via flame graph" (development)

## Caps per session

- ≤20 entities
- ≤25 relations
- ≤40 observations
- Exactly 1 Session entity
- ≤5 observations per entity

If you'd exceed, prioritise: highest evidence weight first. Do not extract trivia.

## Completeness checklist

Before reporting "done", verify explicitly. Recall variance comes from skipping items the transcript clearly contains.

### Concepts — every central named thing
- For every named thing referenced ≥2 times that matters to the outcome: emit a Concept. Cover things mentioned only inside tool output too.
- One-off passing mentions that don't affect the outcome → skip.

### Findings — every discovery/conclusion
- For each distinct conclusion, root cause, insight, hypothesis, or anomaly: emit a Finding with a grounded `summary`.
- Don't conflate two separate findings into one entity.

### Procedures — every repeatable process
- For each multi-step process that worked and could be repeated: emit a Procedure. Single trivial one-step actions are observations, not Procedures.

### Patterns — every real recurrence
- For each failure mode / design pattern / methodology that recurs or is explicitly named: emit a Pattern. Link instances via `INSTANCE_OF`.

### Session — exactly one
- One Session with `session_id`, `occurred_at`, `outcome`, `summary`, and `domain`.

### Self-check before reporting done

Walk back through the transcript. For each line ask: "did I capture this?" Common misses:
- A tool/service/library named only in tool output — yes it counts as a Concept
- A concrete value or threshold reached — emit a Finding observation with that evidence
- A multi-step process — each step is an observation on the Procedure

If the entity count is suspiciously low (e.g. <3 for a substantive multi-topic session), you've under-emitted. Re-read.

## Output artifacts

1. `.athanor/_staging/<session>/manifest.jsonl` — every staged write
2. `.athanor/distilled/sessions/<date>-<session>.md` — session digest (written by kb-committer, NOT the distiller)
3. `.athanor/runbooks/<domain>/<procedure>.md` — appended/created only when a Procedure warrants a written artifact
4. Updates to `.athanor/_state/confidence-ledger.json` (corrections only — promotion is kb-committer's)
   Note: `distill-cursor.json` is written by `session-stop.sh` after confirming the digest — the distiller does NOT write it.
5. Pending-vocab JSON entries if any term was missing

## Smoke test

Run `/athanor validate` to compare against `protocol/test-fixtures/expected-entities.json`. Drift → revisit prompt.
