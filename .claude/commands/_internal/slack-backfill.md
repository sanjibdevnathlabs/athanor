---
description: INTERNAL — replay durable Slack announcements through the existing athanor live-learn pipeline, one post at a time.
---

# _internal/slack-backfill

Replay Slack posts into Athanor using the **existing** live learn flow:

- stage via `kb-write-entity.sh`
- stage via `kb-write-relation.sh`
- stage via `kb-write-observation.sh`
- commit via `kb-learn-commit.sh`

This is a thin replay/orchestration command. No second KB pipeline.

## Inputs

`$ARGUMENTS` supports:

```text
[#channel|channel-id] [--months=N] [--limit=N] [--dry-run|--commit] [--after-ts=<slack-ts>]
```

Defaults:
- channel: `#tech_announcements`
- months: `6`
- mode: `--dry-run`
- no explicit limit

Rules:
- `--commit` = real write path
- `--dry-run` = stage + prepare only, no commit
- if both are omitted, use `--dry-run`
- `--after-ts` overrides saved cursor boundaries

## Cursor file

Use `.athanor/_state/slack-backfill-cursor.json`.

Expected shape:

```json
{
  "channel_id": "",
  "channel_name": "",
  "last_processed_ts": "",
  "last_committed_ts": "",
  "last_mode": "",
  "updated_at": ""
}
```

Semantics:
- `last_processed_ts` = newest Slack ts that finished a clean inspect/stage cycle
- `last_committed_ts` = newest Slack ts that finished a clean commit cycle
- dry-run resume boundary = `last_processed_ts`
- commit resume boundary = `last_committed_ts`
- explicit `--after-ts` beats both

If the file is missing, unreadable, or invalid JSON, treat as fresh state.

## Execution

### 1. Parse args

Interpret `$ARGUMENTS` directly:

- first non-flag token = channel ref
- `--months=N` = lookback window
- `--limit=N` = max accepted root posts to inspect this run
- `--dry-run` / `--commit` = mode
- `--after-ts=<slack-ts>` = explicit resume point

If no channel token is present, use `#tech_announcements`.

### 2. Resolve exact Slack channel

Use Slack MCP tools only.

#### If channel token is already a channel id

Use:
- `mcp__slack-mcp__slack_get_channels` with `channel_id=<id>`

#### If channel token is a name / `#name`

1. Strip leading `#`
2. Paginate `mcp__slack-mcp__slack_get_channels` with:
   - `types="public_channel,private_channel"`
   - `limit=1000`
3. Match exact channel name
4. Stop on first exact match

If no exact channel match is found:

```text
slack-backfill:blocker:channel-not-found:<name>
```

### 3. Load cursor + compute boundaries

1. Read `.athanor/_state/slack-backfill-cursor.json`
2. Compute `start_after_ts`:
   - `--after-ts` if present
   - else `last_committed_ts` in commit mode
   - else `last_processed_ts` in dry-run mode
   - else empty
3. Compute `cutoff_ts` = UTC now minus `N` calendar months
4. Effective lower bound = greater of:
   - `start_after_ts`
   - `cutoff_ts`

### 4. Fetch messages

Use `mcp__slack-mcp__slack_get_channel_messages` with pagination.

Rules:
- fetch newest-first pages until exhaustion
- keep only messages whose numeric `ts` is strictly greater than the effective lower bound
- allow bot/app-authored messages; many announcements are automated

Root-post detection:
- root if `thread_ts` is absent
- root if `thread_ts == ts`
- not root if `thread_ts != ts`

After filtering:
- sort remaining root posts oldest → newest
- apply `--limit` **after** filtering/sorting

### 5. Decide whether a root post is durable

Accept only posts that produce durable work context.

Good candidates:
- launches
- deprecations
- migrations
- breaking changes
- ownership / routing / escalation changes that affect engineering work
- rollout constraints
- durable infra / config / API requirements
- mandatory headers / flags / deadlines / cutovers
- stable tool/service/team knowledge

Skip:
- chatter
- celebrations
- promos / events
- polls
- reminders with no durable rule
- duplicate cross-posts
- transient FYIs
- vague posts that cannot ground a concrete `Finding` / `Concept` / `Procedure` / `Pattern`

One durable `Finding` max per post unless the post clearly contains multiple independent durable facts.

### 6. Thread replies — only when needed

Do **not** fetch every thread blindly.

Fetch thread replies only when the root post has replies and you need to know whether the root was:
- corrected
- superseded
- materially clarified

Use `mcp__slack-mcp__slack_get_thread_replies`.

Rules:
- ignore the parent row returned in the thread payload
- include only replies that materially affect the durable fact
- if a reply corrects the root, learn the corrected final fact, not the stale original wording
- if the thread makes the root non-durable or fully superseded, skip with reason `superseded-in-thread`

### 7. Canonical naming rules

Per accepted post:

```bash
TS_SAFE="<slack-ts with . replaced by ->"
LEARN_SID="slack-tech-announcements-${TS_SAFE}"
```

Dry-run variant:

```bash
LEARN_SID="slack-tech-announcements-${TS_SAFE}-dryrun"
```

Rules:
- one accepted Slack post = one synthetic learn session
- use Slack ts only for `LEARN_SID` / synthetic session identity
- use **semantic** kebab-case canonical names for `Finding` / `Concept` / `Procedure` / `Pattern`
- do not make every `Finding` name just the Slack ts
- if two cross-posts obviously describe the same durable fact, prefer the same semantic canonical name so wrapper dedupe can work

### 8. Timestamp rules

Per accepted post compute:
- `NOW_ISO` = current UTC time
- `POST_ISO` = Slack message ts converted to UTC ISO-8601

Use:
- all entities: `created_at = NOW_ISO`
- synthetic `Session`: `occurred_at = POST_ISO`

### 9. Artifact mapping

Use only the 5 universal entity types.

- `Concept` — named system/service/tool/team/API/header/component
- `Finding` — primary durable announcement record; semantics live in `summary`
- `Procedure` — only if reusable migration / operational steps are present
- `Pattern` — only if the post describes a recurring class of change
- `Session` — one synthetic anchor for this replayed post

Recommended minimum artifact set for most accepted posts:
- 1 `Session`
- 1 `Finding`
- 0..N `Concept`
- optional `Procedure`
- optional `Pattern`
- 1 `Finding OBSERVED_IN Session`
- `Finding REFERENCES Concept` for each named durable concept
- 1 `Finding` observation carrying Slack provenance

Use tuple-safe relations only:
- `Finding REFERENCES Concept`
- `Finding OBSERVED_IN Session`
- `Concept RELATED_TO Concept`
- `Procedure REFERENCES Concept`
- `Finding RESOLVED_BY Procedure` only when the post genuinely states a reusable remediation path
- `Finding INSTANCE_OF Pattern` only when the Pattern is real and reusable

Avoid `CAUSES` / `DEPENDS_ON` / `ALTERNATIVE_TO` unless the post explicitly supports that semantics.

### 10. Stage via wrappers only

Before staging:

```bash
export KB_SESSION_ID="$LEARN_SID"
```

Always stage in this order:
1. entities
2. relations
3. observations

#### Session entity skeleton

```json
{
  "entity_type": "Session",
  "canonical_name": "<LEARN_SID>",
  "session_id": "<LEARN_SID>",
  "occurred_at": "<POST_ISO>",
  "outcome": "completed",
  "summary": "learned from slack #<channel>: <one-line durable fact>",
  "source_session_id": "<LEARN_SID>",
  "created_at": "<NOW_ISO>",
  "domain": "software-engineering"
}
```

#### Finding skeleton

```json
{
  "entity_type": "Finding",
  "canonical_name": "<semantic-kebab-name>",
  "summary": "<10-500 char durable announcement summary>",
  "source_session_id": "<LEARN_SID>",
  "created_at": "<NOW_ISO>",
  "domain": "software-engineering"
}
```

#### Safe default relations

```json
{
  "subject_type": "Finding",
  "subject_name": "<finding-name>",
  "predicate": "OBSERVED_IN",
  "object_type": "Session",
  "object_name": "<LEARN_SID>",
  "source_session_id": "<LEARN_SID>"
}
```

```json
{
  "subject_type": "Finding",
  "subject_name": "<finding-name>",
  "predicate": "REFERENCES",
  "object_type": "Concept",
  "object_name": "<concept-name>",
  "source_session_id": "<LEARN_SID>"
}
```

#### Finding observation skeleton

```json
{
  "entity_type": "Finding",
  "entity_name": "<finding-name>",
  "observation": "Slack announcement in #<channel> at <POST_ISO> by <author-id>. Root text captured for provenance. Include selected corrective/clarifying reply context only when materially relevant.",
  "evidence_snippet": "<verbatim root text or corrected final Slack text, >=20 chars>",
  "source_session_id": "<LEARN_SID>"
}
```

Permalink rule:
- include a permalink in `observation` only if a Slack tool returns one directly
- do not guess Slack URLs

### 11. Wrapper result handling

Read wrapper output literally.

- `ok:<id>` → continue
- `skip:already-written:<id>` → continue
- `reject:predicate-not-in-locked-vocabulary:*` → stop this post; protocol bug or wrong predicate choice
- `reject:tuple-not-in-schema:*` → stop this post; wrong relation choice
- any other `reject:*` → stop this post and surface exact reason

Do **not** call `mcp__knowledge-graph__*` directly.

Do **not** auto-append pending vocab additions for random service/tool names. In v2, service/tool names belong in free-form `canonical_name` fields, not closed vocab files.

### 12. Prepare staged manifest for inspection

After staging an accepted post, always run:

```bash
bash .claude/hooks/lib/kb-prepare-commit.sh \
  ".athanor/_staging/$LEARN_SID/manifest.jsonl" \
  ".athanor/_staging/$LEARN_SID/manifest-prepared.jsonl"
```

Rules:
- if prepare fails, stop this post
- if `manifest-prepared.jsonl` is empty or missing, stop this post
- in dry-run mode, this prepared manifest is the inspection artifact

### 13. Dry-run behavior

For `--dry-run`:
- stage artifacts
- prepare manifest
- do **not** call `kb-learn-commit.sh`
- print one concise per-post line:

```text
slack-backfill:dry-run ts=<ts> accepted=<yes|no> entities=<n> relations=<n> observations=<n> reason=<skip-reason|prepared>
```

Cursor updates in dry-run:
- after a clean dry-run inspect, update `last_processed_ts`
- do **not** touch `last_committed_ts`
- set `last_mode` to `dry-run`

### 14. Commit behavior

For `--commit`:

```bash
bash .claude/hooks/lib/kb-learn-commit.sh "$LEARN_SID"
```

Rules:
- commit immediately per accepted post
- do not pass `LIVE_SID`
- `kb-learn-commit.sh` may still exit 0 when the post was committed but supervision returned `reject`, `revise`, `escalate`, or `none`
- therefore, inspect the script's reported `supervised:<outcome>` result literally; only `supervised:approve` counts as clean progress during the replay command itself
- if the reported supervisor outcome is anything other than `approve`, stop replay and surface the blocker
- after a clean commit, update both `last_processed_ts` and `last_committed_ts`
- set `last_mode` to `commit`
- if a committed post later lands in HITL as `learn_supervisor_no_outcome` and manual review accepts it as-is, the review flow must advance `last_committed_ts` and `last_processed_ts` to that post ts and set `last_mode` to `commit`; otherwise the next commit-mode replay will reprocess an already-accepted post

### 15. Cursor writeback

After each clean post in the selected mode, rewrite `.athanor/_state/slack-backfill-cursor.json` with:

```json
{
  "channel_id": "<resolved-channel-id>",
  "channel_name": "<resolved-channel-name>",
  "last_processed_ts": "<latest-clean-ts>",
  "last_committed_ts": "<latest-committed-ts or previous value>",
  "last_mode": "<dry-run|commit>",
  "updated_at": "<NOW_ISO>"
}
```

### 16. Stop conditions

Stop immediately on:
- channel resolution failure
- Slack auth failure
- malformed cursor state you cannot recover from
- wrapper `reject:*`
- `kb-prepare-commit.sh` failure
- `kb-learn-commit.sh` failure
- supervisor non-approve outcome

Do not bulldoze past protocol failures.

## Output

Keep output terse.

Final summary:

```text
slack-backfill: channel=<name> scanned=<n> accepted=<n> skipped=<n> committed=<n> mode=<dry-run|commit> cursor=<ts>
```

If blocked:

```text
slack-backfill:blocker:<reason>
```

## Out of scope

- no new schema
- no new graph/vector/digest/supervisor pipeline
- no monthly synthetic distill batches
- no automatic daily Slack sync
- no user-facing `/athanor` command changes
- no direct Neo4j writes
