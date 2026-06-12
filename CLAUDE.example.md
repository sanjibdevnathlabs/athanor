# CLAUDE.example.md — Domain-Specific Configuration Template

This is an EXAMPLE overlay showing how to wire athanor into a specific environment's
codebases, MCP tools, and conventions. The base `CLAUDE.md` ships only the universal
protocol rules; everything here is environment-specific.

To use: copy the relevant sections into a `CLAUDE.local.md` (gitignored) in this directory,
replacing every `<your-path>`, `<your-cluster>`, and `<your-service>` placeholder with your
real values. Claude Code does NOT auto-load `CLAUDE.local.md` — either add an `@import`
reference from `CLAUDE.md` or paste the relevant sections directly into `CLAUDE.md`.

---

## Known Codebases (source map)

The codebases listed below sit under a parent workspace container directory (one level up from this repo). This table is a map of what each service owns — handy when an investigation spans services.

Athanor's vector layer indexes only its OWN KB artifacts (runbooks, sessions, skills), not arbitrary source code — SocratiCode and `codebase_search` have been removed. To trace into the source of any service below, use standard code-search tooling (ripgrep, LSP, your IDE) at the listed path. New codebases get added to this list as they're encountered.

### Go Services

| Service | `projectPath` | What it owns |
|---------|--------------|--------------|
| `<your-service>` | `<your-path>/golang/<your-service>` | UI component configuration |
| `<your-service>` | `<your-path>/golang/<your-service>` | Onboarding, KYC, consent flows |
| `<your-service>` | `<your-path>/golang/<your-service>` | Customer support platform |
| `<your-service>` | `<your-path>/golang/<your-service>` | Campaign management, pricing |
| `<your-service>` | `<your-path>/golang/<your-service>` | Auth / identity |
| `<your-service>` | `<your-path>/golang/<your-service>` | Authorization service |

### PHP Services

| Service | `projectPath` | What it owns |
|---------|--------------|--------------|
| `<your-service>` | `<your-path>/php/<your-service>` | API monolith — payments, merchants, settlements |
| `<your-service>` | `<your-path>/php/<your-service>` | Merchant/Admin dashboard |
| `<your-service>` | `<your-path>/php/<your-service>` | Reporting service |

### JavaScript / Frontend

| Service | `projectPath` | What it owns |
|---------|--------------|--------------|
| `<your-service>` | `<your-path>/javascript/<your-service>` | GraphQL BFF |

### DevOps / Infrastructure

| Repo | `projectPath` | What it owns |
|------|--------------|--------------|
| `<your-service>` | `<your-path>/devops/<your-service>` | Helm K8s manifests |
| `<your-service>` | `<your-path>/devops/<your-service>` | Monitoring alert rule definitions |
| `<your-service>` | `<your-path>/devops/<your-service>` | API gateway Terraform |

> Pass `projectPath` as the full absolute path to the sub-project on this host.

### When to search which repo

- **Payments / API errors** → your API monolith
- **Merchant-facing UI issues** → your frontend BFF + dashboard
- **Auth / session failures** → your identity-provider + authz services
- **Onboarding / KYC** → your merchant-experience service
- **Support tickets** → your care/support service
- **K8s deployment issues** → your kube-manifests repo (find the Helm values for the affected app)
- **Alert definition gaps** → your alert-rules repo

## Currently Integrated MCP Tools

These MCP servers are examples of what can be wired up. New domains add their own — browser-harness for web ops, gh/Linear for product, etc. Prefer them over manual investigation when relevant.

### Observability
- **Coralogix** (`mcp__coralogix-server__*`) — log search (DataPrime), traces, metrics, alerts, incidents. Primary tool for log investigation.
  - `get_logs_v1` — DataPrime query against logs. Always call `read_dataprime_intro_docs_v1` first on a new session.
  - `get_traces_v1` — trace/span queries
  - `list_incidents_v1` / `get_incident_details_v1` — active incidents
  - `manage_alerts` — list/create/update Coralogix alerts
  - `metrics__range_query_v1` — PromQL range queries

- **Grafana** (`mcp__grafana__*`) — dashboards, Prometheus queries, alert rules, Sift investigations.
  - `query_prometheus` — instant or range PromQL against any datasource
  - `list_alert_rules` — see firing alerts
  - `get_sift_investigation` / `list_sift_investigations` — automated RCA investigations
  - `search_dashboards` — find relevant dashboards by name

### Infrastructure
- **k8s-mcp** (`mcp__k8s-mcp__*`) — read-only kubectl across all clusters. No writes.
  - Clusters: `<your-cluster>`, `<your-cluster>`, `<your-cluster>` (list your own cluster names here)
  - `kubectl_execute` — get/describe/logs/top on any cluster
  - `get_infra_component_status` — check cluster-autoscaler, metrics-server, spinnaker, traefik, etc.

- **AWS-MCP** (`mcp__AWS-MCP__*`) — read-only AWS CLI. Covers EC2, EKS, RDS, S3 metadata, ALB logs.
  - `query_alb_logs` — structured ALB access log search (up to 6h window, 500 records)
  - `execute` — any read-only AWS CLI command

### Data & Experiments
- **Redash** (`mcp__redash-prod__*`) — run SQL against production Redash data sources.
  - `redash_run_sql` — direct SQL execution
  - `redash_execute_query` — run existing query by ID

- **Splitz** (`mcp__splitz-mcp__*`) — feature flag / experiment evaluation.
  - `get_experiment` / `evaluate_experiment` — check if a flag is on for a given entity

### Communication
- **Slack** (`mcp__slack-mcp__*`) — search messages, read channels, post updates.
  - Use `slack_search_messages` to find prior incident threads before starting investigation.
  - Use `slack_send_message` to post updates to incident channels.

### Product / Project Tracking
- **DevRev** (`mcp__devrev__*`) — work items (issues/tickets), parts (enhancements), sprints/vistas, timeline entries. Read + write. Configure project-scoped in `.mcp.json` (run via `uvx devrev-mcp`, auth from a `DEVREV_API_KEY` env var) rather than globally.
  - `get_current_user` — resolve the authenticated dev user (and your owner ID for filters)
  - `list_works` / `get_work` — query issues/tickets, filterable by owner, sprint, applies-to-part
  - `get_vista` / `get_sprints` — sprint-board + sprint metadata (decode a board URL's `vista` / `vista_group_item` IDs)
  - `create_work` / `update_work` — create/update work items
  - `search` — cross-object DevRev search
  - Caveat: the MCP exposes only a subset of `works.create`/`works.update` fields. For `priority`, `estimated_effort`, `custom_fields`, or `stage_validation_options`, call the raw DevRev REST API (`POST https://api.devrev.ai/works.update`, `Bearer` auth) instead.

## Key Conventions

- **DataPrime queries**: string literals in single quotes, severity values unquoted (`ERROR`, `CRITICAL`). Check schemas with `get_schemas_v1` before complex queries.
- **Prometheus queries**: never query raw metrics — always wrap in aggregators (`sum`, `avg`, `rate`). Use `by(label)` to segment.
- **kubectl**: always specify `-n <namespace>` explicitly. Default namespace is rarely where services run.
- **Cluster for prod**: name your primary production cluster here (e.g. `<your-cluster>`).
- **ALB logs**: 5-minute delivery delay. Max 6h window per query.
