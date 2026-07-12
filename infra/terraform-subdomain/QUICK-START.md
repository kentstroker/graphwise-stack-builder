# VA Benefits GraphRAG — Quick Start (Workshop)

End-to-end setup from a clean machine to a validated GraphRAG knowledge graph —
**both** the structured ingest (CSV → typed graph nodes) and the unstructured
ingest (documents → chunks → embeddings → concept annotations).

The workshop **ends at the `GraphRAG-Prompt-Validation` notebook**, which puts five
real veteran questions through both retrieval paths and proves the graph + vector store
return grounded, cited evidence — ready to wire into the GraphRAG chat engine (standing
up that chatbot is an optional post-workshop step).

> **This repo is self-contained.** The full source corpus (1,629 markdown files),
> the extracted CSVs, and all modeling/UMLS Turtle files are **already committed**.
> You do **not** scrape anything during the workshop. (Re-generating the corpus
> from scratch is optional and documented in the appendix.)

---

## What you'll build

```
                 ┌─────────────── GraphDB (va-benefits repo) ───────────────┐
 modeling/*.ttl  │  default graph: ontology + taxonomy + schema + UMLS map  │
 output/umls/*   │  named graph:   UMLS clinical vocabulary                  │
                 │  + structured nodes (DiagnosticCode, RatingCriterion, …)  │
 output/csv/*    │  + vak:Chunk nodes  + vak:HAS_CONCEPT annotations         │
 output/<corpus> └──────────────────────────────────────────────────────────┘
                          ▲                              ▲
        structured ingest │              unstructured ingest │
        (n8n Structured   │              (n8n Unstructured     │  + Elasticsearch
         Ingest)          │               Ingest)             │    va-doc-chunks
                                                                    (vectors)
```

| Step | What | Tool |
|---|---|---|
| 1 | Load GraphDB (modeling + UMLS) | GraphDB Workbench |
| 2 | Load Graph Modeling (formerly PoolParty) (ontology + taxonomy) | Graph Modeling |
| 3 | Use the stack n8n + load the GraphRAG seed | stack n8n env, `psql` seed |
| 4 | Structured ingest (load) | n8n *Structured Ingest* |
| 5 | Unstructured ingest (load) | n8n *Unstructured Ingest* |
| 6 | Annotate both datasets (one run) | n8n *Extractor* |
| 7 | Validate structured | `Structured-Validate-GraphDB.ipynb` |
| 8 | Validate unstructured + GraphRAG pre-flight | `Unstructured-Validate-GraphDB.ipynb` |
| 9 | Validate GraphRAG (prompt → grounding) | `GraphRAG-Prompt-Validation.ipynb` |
| 10 | Stand up the chatbot *(optional, post-workshop)* | n8n seed + `Configuration` |
| 11 | Prune n8n execution history *(maintenance)* | n8n *N8N Prune Database* |

---

## Where you'll build it

The knowledge graph and its services do **not** run on your laptop. GraphDB,
Graph Modeling (Thesaurus + Extractor), and Elasticsearch — plus the pre-baked
GraphRAG chat suite — are provided by a separate **Graphwise stack running on
AWS**, provisioned and managed by Terraform:

> **Stack repo:** [`kentstroker/graphwise-stack-builder`](https://github.com/kentstroker/graphwise-stack-builder)
> — *Full Graphwise stack plus GraphRAG on AWS EC2 + Terraform + KIND.*

```
   YOUR LAPTOP (local-first)                AWS  (terraform-provisioned EC2 + KIND)
 ┌───────────────────────────┐           ┌──────────────────────────────────────────┐
 │  kubectl / SSH  (stack)    │  HTTPS    │  single-node Kubernetes (KIND) on one EC2 │
 │  Jupyter validation books  │ ───────▶  │   • GraphDB        graphdb-projects.<dom>  │
 │  AWS Bedrock (embeddings)  │           │   • Graph Modeling poolparty.<dom>         │
 │                            │  SSH      │   • Elasticsearch  (no ingress — tunnel)   │
 │  scripts/es-tunnel.sh ─────┼────────▶  │   • GraphRAG chat suite + n8n + Keycloak    │
 └───────────────────────────┘           └──────────────────────────────────────────┘
```

**Why a hosted stack.** Graph Modeling, GraphDB, and the Graphwise GraphRAG suite are
a multi-service Helm deployment with SSO, TLS, and inter-service wiring — far
more than a laptop should run. Terraform makes it one repeatable command instead
of hand-built infrastructure.

**What `terraform apply` stands up** (high level — see the stack repo's
`QUICKSTART.md` / `DEPLOY.md` for the real runbook):

1. An EC2 host (Amazon Linux 2023, ARM64) with Docker + **KIND** (Kubernetes-in-
   Docker) + Helm bootstrapped via cloud-init — a single-node cluster.
2. Two Helm installs deploy the **Graphwise umbrella** (Graph Modeling, two GraphDB
   instances, Elasticsearch, Keycloak, Semantic Workbench, …) and the **GraphRAG**
   suite (chatbot + conversation API + seeded n8n workflows), each on its own
   public subdomain with a Let's Encrypt cert and Keycloak SSO.
3. A pre-allocated Elastic IP + DNS wildcard give every service a stable URL
   under `<subdomain>.<base-domain>` — e.g. this guide's
   `graphdb-projects.va-benefits.semantic-demo.com`.

**How this workshop connects to it:**

| This workshop uses… | …served by the stack as | Reached from your laptop via |
|---|---|---|
| GraphDB (`va-benefits` repo) | `graphdb-projects.<domain>` | HTTPS (public ingress) |
| Graph Modeling extractor | `poolparty.<domain>` | HTTPS (public ingress) |
| Elasticsearch (`va-doc-chunks`) | in-cluster, **no public ingress** | reached by the stack n8n via in-cluster service — no tunnel needed |
| Bedrock embeddings | AWS Bedrock (Titan) | `AWS_*` keys — in the `n8n-poc-creds` Secret for ingest (Step 3.1); in the env or a local `.env` for the laptop validation notebook |

> **For the workshop you only need *access* to a running stack** (the endpoints +
> credentials in the Prerequisites). Standing the stack up from scratch is the
> stack repo's job, not this guide's. The same `GRAPHWISE_KEY/HOST/USER` SSH
> values are the ones produced when that stack is deployed.

---

## Prerequisites

| Tool / access | Needed for | Notes |
|---|---|---|
| Python 3.11+ | the validation notebooks | `python3 --version` |
| `kubectl` + SSH to the EC2 host | run the stack n8n, load the seed | `GRAPHWISE_*` vars (Step 3) — n8n runs **on the stack**, not locally |
| GraphDB access | the knowledge graph | `https://graphdb-projects.va-benefits.semantic-demo.com` |
| Graph Modeling access | concept annotation | `https://poolparty.va-benefits.semantic-demo.com` (extractor user + password) |
| AWS Bedrock credentials | chunk embeddings (Titan v2) | access key/secret with `bedrock:InvokeModel` in `us-west-2` |
| SSH access to the EC2 host | running stack commands (`kubectl`, seed load) | `GRAPHWISE_KEY`, `GRAPHWISE_HOST`, `GRAPHWISE_USER` env vars |
| UMLS API key | *only* if re-extracting UMLS (appendix) | https://uts.nlm.nih.gov/uts/profile |

Install the notebook dependencies once:

```bash
pip install -r requirements.txt      # pandas, requests, jupyter, …
```

---

## Step 1 — Load GraphDB

**First, create the repository.** In the GraphDB Workbench, go to **Setup → Repositories →
Create new repository → GraphDB Repository** and configure:

- **Repository ID:** `va-benefits`
- **Ruleset:** **OWL-Max (Optimized)** — the reasoner the ontology/taxonomy rely on
- **Supports context index:** ✅ enabled — required for the named-graph imports below
- **Enable full-text search (NLP):** ✅ enabled

Create it, then **make it the active repository** (click the connect/"pin" icon next to
`va-benefits` in the repository list) before importing anything. Also go to
**Setup → Autocomplete** and enable it for the `va-benefits` repository — GraphDB's
MCP server requires Autocomplete to be on.

Then import these into GraphDB repository **`va-benefits`**, in order. The named-graph
URI must be entered **exactly** as shown (trailing slash included).

| # | File | Target graph |
|---|---|---|
| 1 | `modeling/ontology.ttl` | *default graph* |
| 2 | `modeling/taxonomy.ttl` | *default graph* |
| 3 | `modeling/schema.ttl` | *default graph* |
| 4 | `output/umls/umls_va_mappings.ttl` | *default graph* |
| 5 | `output/umls/umls_concepts.ttl` | `https://uts.nlm.nih.gov/metathesaurus/` |
| 6 | `output/umls/umls_hierarchy.ttl` | `https://uts.nlm.nih.gov/metathesaurus/` |
| 7 | `output/umls/umls_condition_concepts.ttl` | `https://uts.nlm.nih.gov/metathesaurus/` |

> The **structured** data (diagnostic codes, rating criteria, etc.) is loaded by
> n8n in Step 4 and the **chunk** nodes in Step 5; their `vak:HAS_CONCEPT` tags are
> written by the **Extractor** in Step 6 — do **not** import those manually.

---

## Step 2 — Load Graph Modeling

**First-time login.** Sign in to Graph Modeling with the default credentials
**`superadmin` / `poolparty`**. You'll be prompted to set a new password — set it to
**`corgiDAD#2`** (use exactly this value; the rest of the runbook and stack config
assume it).

**Create the project.** Create a new project named **`VA Benefits`** and **note its
project ID** — you'll need it for the import below and for the Extractor wiring. The ID
shown here (`c17d15cf-a078-4bfb-959c-7b4cb1aae336`) is from the reference build; **yours
will differ** — substitute it wherever this ID appears.

Import into your Graph Modeling project (`c17d15cf-a078-4bfb-959c-7b4cb1aae336` in the
reference build), in order:

| # | File | Import type | Notes |
|---|---|---|---|
| 1 | `modeling/ontology.ttl` | **Ontology** | OWL class definitions |
| 2 | `modeling/taxonomy.ttl` | **Thesaurus** | SKOS vocabulary — 100 concepts in 4 schemes |
| 3 | `output/umls/umls_condition_concepts.ttl` | **Thesaurus** | condition-level CUIs with SNOMED/MeSH/ICD-10 altLabels, `skos:broader` → VA body-system |
| 4 | `modeling/schema.ttl` | **Project container** | wires OWL classes to taxonomy concepts (set `ppt:BaseUrl` to your server first) |

Then: **Corpus → Rebuild Extraction Model**, and wait for it to finish before
running the Extractor (annotation).

> **Don't skip the rebuild on a new project.** Importing the thesaurus does *not*
> populate the extractor's concept index. Until you Rebuild Extraction Model, every
> Extractor call fails with `HTTP 400: Concept Index is empty for projectId …`, and the
> Extractor's `Aggregate` guard aborts before touching the graph. Also confirm you
> imported the thesaurus into the project whose ID you put in `EXTRACTOR_PROJECT_ID`.

**Connect Graph Modeling to GraphDB.** In the Graph Modeling admin UI go to
**Systems → Graph Databases → GraphDB → Create** and set the **URL** field to:

```
https://graphdb-projects.kaiser.gw-pse.com/repositories/coverage
```

This is the full Kubernetes in-cluster DNS name for the `graphdb-projects` service
(namespace `graphdb`). The short form `graphwise-stack-graphdb-projects.graphdb:7200`
does **not** resolve reliably from the PoolParty pod — use the full `.svc.cluster.local`
form.

---

## Step 3 — Set up the stack n8n

All workflows — the three ingest workflows and the chatbot suite — run on the **stack's
n8n** (`graphrag-workflows`, namespace `graphrag`). Complete all sub-steps below before
running any workflow. Run kubectl commands on the **EC2 host** unless noted otherwise.

### 3.1 — Write `~/n8n.txt` (on the EC2 host)

One `KEY=VALUE` per line — no quotes, no trailing spaces (`--from-env-file` takes
everything after `=` literally):

```
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
EXTRACTOR_AUTH=Basic <base64>
EXTRACTOR_PROJECT_ID=<your-graph-modeling-project-uuid>
```

Generate `EXTRACTOR_AUTH` with `printf` (not `echo` — echo adds a trailing newline that
makes the extractor return 401):

```bash
printf 'superadmin:corgiDAD#2' | base64
```

Prefix the result: `EXTRACTOR_AUTH=Basic <output>`. `EXTRACTOR_PROJECT_ID` is the Graph
Modeling project UUID from Step 2 — it must exist before this file is written.

### 3.2 — Create the Kubernetes Secret

```bash
kubectl -n graphrag create secret generic n8n-poc-creds --from-env-file="$HOME/n8n.txt"
```

If the secret already exists from a prior run, delete it first:

```bash
kubectl -n graphrag delete secret n8n-poc-creds && kubectl -n graphrag create secret generic n8n-poc-creds --from-env-file="$HOME/n8n.txt"
```

### 3.3 — Inject environment variables into the n8n Deployment

Credentials from the Secret, then the behavior flags (two commands):

```bash
kubectl -n graphrag set env deploy/graphrag-workflows --from=secret/n8n-poc-creds
```

```bash
kubectl -n graphrag set env deploy/graphrag-workflows N8N_BLOCK_ENV_ACCESS_IN_NODE=false NODE_FUNCTION_ALLOW_BUILTIN='*' NODE_FUNCTION_ALLOW_EXTERNAL=js-tiktoken N8N_ALLOW_CODE_NODE_EXTERNAL_FILES=true N8N_RUNNERS_TASK_TIMEOUT=1800 N8N_RUNNERS_HEARTBEAT_INTERVAL=600
```

```bash
kubectl -n graphrag rollout status deploy/graphrag-workflows
```

> These are live patches to the Deployment. A future `helm upgrade` wipes them — re-run
> both commands if you see "access to env vars denied."

| Flag | Why |
|---|---|
| `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` | lets nodes read `{{ $env.* }}`; without it the Config node fails |
| `NODE_FUNCTION_ALLOW_BUILTIN=*` | Code nodes may `require()` Node built-ins |
| `NODE_FUNCTION_ALLOW_EXTERNAL=js-tiktoken` | Unstructured Ingest's token-accurate chunker |
| `N8N_ALLOW_CODE_NODE_EXTERNAL_FILES=true` | Code-node file access |
| `N8N_RUNNERS_TASK_TIMEOUT=1800` | long corpus runs (~30 min) don't get killed |
| `N8N_RUNNERS_HEARTBEAT_INTERVAL=600` | headroom for large docs; the Chunk node yields every 25 docs so heartbeats fire regardless |

### 3.4 — Restore the n8n database

The GraphRAG n8n is restored from a **full database mirror** (`pg_dump -Fc` of a
known-good n8n), not a SQL seed. Because `N8N_ENCRYPTION_KEY` is constant across stack
builds, the mirror restores with all workflows and live credentials intact. Full mirror
procedure: **[`MIRROR-N8N.md`](MIRROR-N8N.md)**.

The restore script stops n8n, wipes the database, loads the mirror, grants permissions,
and restarts n8n:

```bash
./scripts/restore-n8n-dumpall.sh
```

```bash
kubectl -n graphrag rollout status deploy/graphrag-workflows
```

### 3.5 — Log in to the n8n UI

Open `https://workflows.<your-subdomain>` and log in with the pre-seeded admin account:

- **Email:** `kent.stroker@graphwise.ai`
- **Password:** `graphDB#1`

### 3.6 — Rotate the n8n API key and create the n8n API credential

The mirror restores `user_api_keys` intact, but the JWT value stored in the **API_KEYS
data table** was generated on the source instance and will not validate on a fresh build.
Rotate it:

1. n8n UI → **Settings → API** → delete `graphwise-graphrag`
2. Create a new key named `graphwise-graphrag` — **copy the value immediately** (only shown once)
3. n8n UI → **Data Tables → API_KEYS** → open the `N8N` row → paste the copied value into the `value` field → save

> **Why step 3:** the data table is what workflow nodes read at runtime to pass the key
> as a header. Skipping it leaves the old (now-invalid) JWT in the table and every
> internal API call returns 401. Step 1–2 handles `user_api_keys` automatically via the UI.

**Create the n8n API credential** so workflow nodes can authenticate against the n8n API:

n8n UI → **Credentials → New → n8n API**:

| Field | Value |
|---|---|
| API Key | the value copied above |
| Base URL | `http://graphrag-workflows:5678` |

Name it `graphwise-graphrag`. Then find any HTTP Request nodes in the seeded workflows
that call `http://graphrag-workflows:5678` and assign this credential to them.

> **The N8N Prune Database workflow (Step 11) needs a second credential** with a different
> Base URL — see Step 11 for details. Same API key, different URL.

### 3.7 — Fill n8n credentials

Open n8n UI → **Credentials**. After a full mirror restore the values may already be
populated (the mirror carries real encrypted blobs and the encryption key is constant) —
verify first and skip if filled.

**Main LLM Model credentials** (type: AWS):

| Field | Value |
|---|---|
| Access Key ID | `AWS_ACCESS_KEY_ID` from `~/n8n.txt` |
| Secret Access Key | `AWS_SECRET_ACCESS_KEY` from `~/n8n.txt` |
| Region | `us-west-2` |

**PoolParty Credentials** (type: HTTP Basic Auth):

| Field | Value |
|---|---|
| Username | Graph Modeling extractor username (`superadmin`) |
| Password | Graph Modeling extractor password (`corgiDAD#2`) |

**Keycloak clientId / clientSecret** (type: HTTP Basic Auth):

| Field | Value |
|---|---|
| Username | `conversation-api-client` |
| Password | Keycloak client secret — Keycloak admin → realm `graphrag` → Clients → `conversation-api-client` → Credentials tab |

> ⚠️ The Keycloak client secret is **generated per stack build** — it is not a shared
> default and differs per deployment. Always retrieve it from Keycloak admin. If wrong,
> the JWT token verification sub-workflow returns `{"active": false}` and the chatbot
> silently rejects every request.

### 3.8 — Verify n8n is up

In the n8n UI confirm:
- Workflows list is populated (~31 workflows)
- The `Main` workflow exists and shows as active

### 3.9 — Edit the Configuration node

Open the **`Configuration`** workflow from the Workflows list, then open its **Code
node** and update the four deployment-specific fields below. **Save the workflow after
editing.**

> The `Configuration` workflow is a standalone workflow — `Main` and `Parallel - Main`
> call it via Execute Workflow. The repo file `n8n-workflows/Configuration.js` is an
> inert mirror; edits there do nothing to the running n8n.

| Field | Change to |
|---|---|
| `graphDBMcpUrl` | `https://graphdb-projects.<your-domain>/mcp` |
| `keycloakUrl` | `https://auth.<your-domain>` |
| `poolPartyServerUrl` | `https://poolparty.<your-domain>` |
| `poolPartyProjectId` | the Graph Modeling project UUID (`EXTRACTOR_PROJECT_ID` from `~/n8n.txt`) |

```js
const backendUrl = "http://graphrag-conversation:8080";
const graphRagComponentsUrl = "http://graphrag-components:8080";

return {
  backendUrl,
  backendSseMessageUrl: `${backendUrl}/sse/message`,

  // *** EDIT: replace with https://graphdb-projects.<your-domain>/mcp ***
  graphDBMcpUrl: "https://graphdb-projects.va-benefits.gw-pse.com/mcp",
  graphDBMcpRepository: "va-benefits",
  graphDBMcpOntologyGraph: "",
  graphDBMcpFtsSearchTriplesLimit: 100,

  internalN8nUrl: "http://graphrag-workflows:5678",

  // *** EDIT: replace with https://auth.<your-domain> ***
  keycloakUrl: "https://auth.va-benefits.gw-pse.com",
  keycloakRealm: "graphrag",

  mcpLLMModel: "us.anthropic.claude-sonnet-4-6",
  primaryLLMModel: "us.anthropic.claude-sonnet-4-6",
  secondaryLLMModel: "us.anthropic.claude-sonnet-4-6",

  // *** EDIT: replace with https://poolparty.<your-domain> ***
  poolPartyServerUrl: "https://poolparty.va-benefits.gw-pse.com",
  // *** EDIT: replace with EXTRACTOR_PROJECT_ID from ~/n8n.txt ***
  poolPartyProjectId: "f0e3d316-524c-4155-a760-4599d2abc9bb",

  vectorSearchUrl: `${graphRagComponentsUrl}/vector/search`,

  "vectorStorePreset": "elasticsearch_native",
  "vectorStoreCustomMappins": {},
  "vectorStoreMetadataPassthrough": true,
  "vectorStoreMetadataExclude": [],

  "vectorIndex": "va-doc-chunks",
  "embeddingsProvider": "aws",
  "embeddingsModelId": "amazon.titan-embed-text-v2:0",

  "conceptProperties": ["skos:prefLabel", "skos:altLabel", "skos:definition", "skos:scopeNote", "skos:example", "skos:broader", "skos:narrower", "skos:related"],

  shortMemoryMaxUncompressedSizeInTokens: 300,
  parallelStepsMaxTiemout: 65
};
```

### 3.10 — Stage the data files (from your laptop)

Copy the `output/` tree to the EC2 host (~1,600 files, takes a few minutes):

```bash
scp -r -i "$GRAPHWISE_KEY" output "$GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/"
```

On the EC2 host, fix permissions so the n8n pod (different uid) can read and write:

```bash
chmod -R a+rwX ~/staging-data/output
```

> Re-run after regenerating the corpus with `Prepare-Source-Data.ipynb`.

### 3.11 — Mount the staging PVC into the n8n pod

```bash
CNAME=$(kubectl -n graphrag get deploy graphrag-workflows -o jsonpath='{.spec.template.spec.containers[0].name}') && kubectl -n graphrag patch deploy graphrag-workflows --type=strategic -p "{\"spec\":{\"template\":{\"spec\":{\"volumes\":[{\"name\":\"staging\",\"persistentVolumeClaim\":{\"claimName\":\"staging-data\"}}],\"containers\":[{\"name\":\"$CNAME\",\"volumeMounts\":[{\"name\":\"staging\",\"mountPath\":\"/data/staging\"}]}]}}}}"
```

```bash
kubectl -n graphrag rollout status deploy/graphrag-workflows && kubectl -n graphrag exec deploy/graphrag-workflows -- ls /data/staging/output/csv | head
```

Should list `diagnostic_codes.csv` and the other CSVs. If `staging-data` PVC is missing,
it wasn't created in the graphrag namespace — that is a stack/Helm concern. Like the env
patch, this mount is reverted by a future `helm upgrade` — re-apply if needed.

### Re-apply after a `helm upgrade`

Any `helm upgrade` wipes the live env patches and PVC mount. Re-run Steps 3.3 and 3.11.

---

## Step 4 — Structured ingest (n8n)

In the **stack n8n** (Step 3.1), **Import from File** `n8n-workflows/Structured
Ingest.json`.

**Before running, open the `Config` node and update the two subdomain-specific fields:**

| Field | Set to |
|---|---|
| `graphdb` | `https://graphdb-projects.<your-domain>/repositories/va-benefits/statements` |
| `poolparty` | `https://poolparty.<your-domain>/extractor/api/tag` |

> The committed values bake in the reference build's domain — they must change for every new deployment. The other fields (`csvDir`, `rdfDir`, `extractorProjectId`, `extractorAuth`) do not change: the paths are pod-local and the credentials come from the stack n8n env via `{{ $env.* }}` (Step 3.1).

Open **Structured Ingest** → **Execute Workflow**. It converts the CSVs into typed
graph nodes (`DiagnosticCode`, `RatingCriterion`, `PresumptiveCondition`,
`M21Article`) and loads them into GraphDB. *Concept tagging happens later, in Step 6
— this step only loads the data.*

---

## Step 5 — Unstructured ingest (n8n)

**Import from File** `n8n-workflows/Unstructured Ingest.json`.

**Before running, open the `Config` node and update the subdomain-specific field:**

| Field | Set to |
|---|---|
| `graphdb` | `https://graphdb-projects.<your-domain>/repositories/va-benefits/statements` |

> All other fields are deployment-invariant: `esUrl` is the in-cluster Elasticsearch service name (consistent across stack builds), `stagingDir` is the pod-local PVC path, and the AWS credentials come from env via `{{ $env.* }}` (Step 3.1).

Then open **Unstructured Ingest** → **Execute Workflow**. It reads the committed corpus from
`/data/staging/output` (staged + mounted in **Step 3.3**), splits each document into
token-bounded chunks, embeds each with **AWS Bedrock Titan v2**, writes the vectors
to the Elasticsearch index `va-doc-chunks`, and writes `vak:Chunk` nodes into
`<https://va-benefits.example/kg/chunks/>`.

> ⚠️ **Reads from the mounted corpus (Step 3.3).** The workflow's Config path is
> `/data/staging/output`. If you get `ENOENT … /data/staging/output/...`, the files
> aren't staged or the PVC isn't mounted — (re)do **Step 3.3** (`rsync output/` up +
> `kubectl patch` the PVC mount), then re-run.

- The two `Limit (TEST: …)` nodes are **disabled**, so the full corpus is processed.
  (Re-enable them — press `D` on each — for a quick test slice.)
- Embeddings are **cached** to `output/embeddings-cache.json`; re-runs reuse cached
  vectors for unchanged text (no time, no cost).
- ⚠️ **If `va-doc-chunks` already exists from an earlier mapping, delete it first**
  (`curl -X DELETE localhost:9200/va-doc-chunks`) so the current single-`embedding`
  mapping takes effect — `Create: ES Index` no-ops on an existing index.

See `markdown/UNSTRUCTURED-INGEST.md` for the node-by-node detail.

---

## Step 6 — Annotate both datasets (the Extractor)

**Import from File** `n8n-workflows/Extractor.json`.

**Before running, update the subdomain-specific fields in two nodes:**

**`Config` node:**

| Field | Set to |
|---|---|
| `graphdb` | `https://graphdb-projects.<your-domain>/repositories/va-benefits/statements` |
| `poolparty` | `https://poolparty.<your-domain>/extractor/api/tag` |

**`PP Heartbeat` node — URL field:**

| Field | Set to |
|---|---|
| URL | `={{ $('Config').first().json.poolparty.replace('/tag', '/heartbeat') }}` |

> The heartbeat node's URL is also hardcoded to the reference domain — it will SSL-error against the wrong host if not updated. Using the expression above derives it from Config so there is only one place to change per deployment.

Then open **Extractor** →
**Execute Workflow**. **One run tags both** the structured nodes and the chunks:
it runs the pre-flight gates (extractor heartbeat → project → UMLS vocab), queries
every text-bearing node (structured rows **and** `vak:Chunk`), calls the Graph
Modeling extractor in parallel, and writes `vak:HAS_CONCEPT` triples into **two**
graphs — `<…/kg/annotations/>` (structured) and `<…/kg/chunk-annotations/>` (chunks).

It drops and rebuilds both annotation graphs each run, so it is safe to re-run
whenever the taxonomy or extraction model changes (Step 2). The ingest workflows
only need a re-run when their source data changes.

---

## Step 7 — Validate the structured graph

Open **`notebooks/Structured-Validate-GraphDB.ipynb`**, set the SPARQL endpoint in
the configuration cell if needed, and run all cells. The scorecard confirms the
ontology, taxonomy, UMLS vocabulary, structured nodes, and the Extractor's
`HAS_CONCEPT` annotations all loaded correctly.

---

## Step 8 — Validate the unstructured graph

Open **`notebooks/Unstructured-Validate-GraphDB.ipynb`** and run all cells:

- **Part A — ingest:** chunks are embedded, indexed in Elasticsearch, and mirrored
  as `vak:Chunk` nodes; the two stores agree and the cross-store join resolves.
- **Part B — annotation:** `vak:HAS_CONCEPT` tags exist, every tagged concept
  resolves to a real `skos:Concept` (no dangling URIs), and coverage is reported.
- **Part C — GraphRAG pre-flight:** concept-anchored retrieval, vector→graph
  handoff, taxonomy expansion, cross-document bridging, and a **readiness scorecard**.

> **GraphRAG-wireable (Part C.5):** the pre-baked chat engine's `elasticsearch_native`
> preset reads `_source.text`, `_source.metadata.id`, and the vector field
> `embedding`. Unstructured Ingest writes exactly those (a single `embedding`
> vector + `text` + `metadata.id`), so the index satisfies the preset and Part C.5
> shows **READY ✓**. (If you ever change the ES mapping, delete `va-doc-chunks` and
> re-run Step 5 first — see Step 5's note.)

---

## Step 9 — Validate GraphRAG retrieval (workshop finish line)

Open **`notebooks/GraphRAG-Prompt-Validation.ipynb`** and run all cells. This is the
GraphRAG capstone: it puts **five real veteran questions** through the **same two
retrieval paths the chatbot uses** and shows the grounding each should produce —
*before* the chat engine exists, so you have an expected-answer spec to check it against.

> **Needs:** AWS Bedrock creds (from the environment or a local `.env`) — Stage 5
> embeds each question with Titan v2 to run vector search. If missing, the vector
> stages skip and the concept-layer checks still run.

For each question the notebook runs six stages:

1. **Concept resolution** — the question's key term → a taxonomy concept
2. **Concept expansion** — the chatbot's *own* scored SKOS query → related concepts
3. **Concept → chunk grounding** — the document chunks tagged with those concepts
4. **Cross-document bridge** — how many source documents that grounding spans
5. **Vector kNN** — the ranked top-*k* chunks the chatbot will cite (Bedrock + ES)
6. **Bridge + assertion** — do the vector hits carry the concepts we predicted?

The scorecard confirms each prompt reproduces both the **concept set** (Stages 1–2,
exact) and the **ranked citations** (Stage 5). These are the expected-grounding spec
you compare the live chatbot against in Step 10.

> **Two things the notebook flags, to confirm later against the live stack:** `TOP_K`
> is a placeholder (set it to the engine's `/vector/search` `top_k`), and these are
> *predicted* groundings — nothing is checked against the chatbot until Step 10.

---

## Step 10 — Finish & activate the GraphRAG chatbot (optional, after the workshop)

The chatbot's 28 workflows were **already seeded** into the stack n8n back in **Step
1.2** (that's why it had to run before ingest — to preserve the fixed IDs). Now that the
graph + vector store are populated and validated, three moves bring the chatbot online:
**fill credentials → set the `Configuration` node → activate**.
(`GraphRAG-Prompt-Validation.ipynb` from Step 9 is the expected-grounding spec you
check it against.)

> **Full n8n-workflow reference:** [`GRAPHRAG-WORKFLOWS.md`](GRAPHRAG-WORKFLOWS.md)
> consolidates everything the workflows need — environment (incl. the **webhook
> base-path** env that makes the chat webhook reachable), credentials, the
> `Configuration` mapping, activation, and the **test-vs-production webhook** rules with a
> smoke-test decision table. Read it if the chat webhook "shows nothing entering it."

### 11.1 — Fill the credentials (they ship **empty**)

The seed's 7 credential rows have blank `data`, so open each in the n8n UI and fill it.
For **this** deployment (Elasticsearch + Bedrock) you only need three:

| Credential (n8n) | Fill? | With |
|---|---|---|
| **Main LLM Model credentials** (`aws`) | ✅ | Bedrock keys + region — the answer / GraphDB-MCP LLM |
| **PoolParty Credentials** (`httpBasicAuth`) | ✅ | the extractor user:pass (same identity as `EXTRACTOR_AUTH`) |
| **Keycloak clientId / clientSecret** | ✅ *(if SSO is on)* | the suite's Keycloak client creds |
| Fallback LLM Model account - OpenAi | optional | only if you want an OpenAI fallback |
| PineconeApi / QdrantApi / Weaviate | ❌ leave empty | unused — we use the `elasticsearch_native` preset |

### 11.2 — Set the `Configuration` node, then activate

The seed ships the `Configuration` node with placeholder/example values (`example.com`
hosts, `opensearch_native`, dummy UUIDs). Open the **`Configuration`** node (in the
`Main` workflow) and replace the `return {…}` body with the deployment-specific version
kept at **[`n8n-workflows/Configuration.js`](../n8n-workflows/Configuration.js)** — the
curated source of truth for this stack. The values that must change from the seed defaults:

| Field | Set to | Why |
|---|---|---|
| `backendUrl` | `http://graphrag-conversation:8080` | internal svc name (seed's `conversation-service` doesn't exist) |
| `internalN8nUrl` | `http://graphrag-workflows:5678` | the stack n8n service (seed says `n8n:5678`) |
| `graphDBMcpUrl` | `https://graphdb-projects.va-benefits.semantic-demo.com/mcp` | live GraphDB MCP — **HTTP Streamable** transport (the deprecated `/mcp/sse` SSE path returns 406); also set the MCP Client node's Server Transport to "HTTP Streamable" |
| `graphDBMcpRepository` | `va-benefits` | the repo from Step 1 |
| `poolPartyServerUrl` | `https://poolparty.va-benefits.semantic-demo.com` | the extractor host |
| `poolPartyProjectId` | `$env.EXTRACTOR_PROJECT_ID` | same project the Extractor uses (single source of truth) |
| `vectorStorePreset` | `elasticsearch_native` | seed defaults to `opensearch_native` |
| `vectorIndex` | `va-doc-chunks` | this build's `graphrag-components` has no `INDEX` env, so the index name must live here |
| `embeddingsProvider` | `aws` | Bedrock |
| `embeddingsModelId` | `amazon.titan-embed-text-v2:0` | **must byte-match the corpus model** (Unstructured Ingest embedded chunks with `amazon.titan-embed-text-v2:0`). The seed's `cohere.embed-english-v3` — or dropping the `:0` — silently breaks kNN |
| `primaryLLMModel` / `secondaryLLMModel` | a **Bedrock** Claude ID | seed's `openai.gpt-4.1` won't work (no OpenAI credential) |
| `top_k` (vector search) | match `TOP_K` in `GraphRAG-Prompt-Validation.ipynb` | keeps the live chatbot aligned with the validated retrieval |

- `graphDBMcpOntologyGraph` — leave **empty** (`""`). Step 1 loads `ontology.ttl` into the **default graph**, and empty = the default graph.

> **Confirm before activating:**
> - **LLM model IDs** — Bedrock IDs must be ones your account/region has enabled. `Configuration.js` sets all three LLM slots to `us.anthropic.claude-sonnet-4-6` (the cross-region **inference-profile** ID; bare foundation-model id is `anthropic.claude-sonnet-4-6`, no date/version suffix) — this deployment's working model. Don't set an ID that isn't enabled — it 400s. Access needs both IAM `bedrock:InvokeModel*` on the profile **and** the bare per-region foundation-model ARNs (us-east-1/us-east-2/us-west-2), plus `aws-marketplace:Subscribe` to enable model access.

Then **activate** the `Main` (webhook-triggered) workflow.

### 11.3 — Smoke test

Ask the chatbot *"How does VA establish service connection for a disability?"* It
should return a grounded, cited answer. Compare its concepts + cited sources against
**Prompt 1** in `GraphRAG-Prompt-Validation.ipynb`. If it **hangs**, the workflows
aren't seeded or a credential is empty (see Troubleshooting); if it returns **no
sources**, the `Configuration` preset/index is wrong.

---

## Step 11 — Prune the n8n execution history (maintenance)

The **N8N Prune Database** workflow deletes old execution records from the n8n database.
Execution rows accumulate quickly during active ingest runs and can grow to thousands of
records, slowing the n8n UI.

The workflow may already be present in the mirrored database. If not, **Import from File**
`n8n-workflows/cleanup.json`.

### 12.1 — Create the `n8n Internals` credential

The `Get many executions` and `Delete an execution` nodes both use an **n8n API**
credential. The `n8n-nodes-base.n8n` node type appends only the bare resource path
(`/executions`) to the credential's Base URL — it does **not** add `/api/v1` itself.
The Base URL must therefore include `/api/v1`:

| Field | Value |
|---|---|
| Name | `n8n Internals` |
| API Key | the key created in Step 3.6 (Settings → API → `graphwise-graphrag`) |
| Base URL | `http://graphrag-workflows:5678/api/v1` |

> **Why the non-obvious `/api/v1` suffix:** setting the Base URL to
> `http://graphrag-workflows:5678` (without it) causes the node to call
> `/executions` instead of `/api/v1/executions`, returning **404** with the
> misleading message "The resource you are requesting could not be found" — even
> though the API is up and the key is valid. The standard `graphwise-graphrag`
> credential (Step 3.6) omits `/api/v1` because HTTP Request nodes construct the
> full path themselves; the n8n node type does not.

Assign this credential to both the **Get many executions** and **Delete an execution**
nodes in the workflow.

### 12.2 — Enable Return All

In the **Get many executions** node, turn on the **Return All** toggle. Without it the
node fetches only the first page (~100 executions) and leaves the remainder untouched.
With Return All enabled it pages through the entire execution history before handing the
full list to the delete step.

### 12.3 — Run

In the **Set Executions to Keep** node set `executionsToKeep` to `0` to purge
everything, or a positive integer to keep that many recent executions per workflow.
Execute the workflow.

The delete node returns each deleted record with `deletedAt: null` — this is expected
for a hard delete (the field is null before removal; the record is gone from the DB).
If the execution count was very large, run the workflow a second time to catch any
records beyond the first full page that were returned on the initial fetch.

---

## Re-run triggers

| What changed | Action |
|---|---|
| CSV / structured data | Re-run **Structured Ingest**, then the **Extractor** if tagging matters |
| Taxonomy or extraction model (Graph Modeling) | Rebuild Extraction Model, re-run the **Extractor** |
| Source documents (corpus) | Re-run **Unstructured Ingest** (only new/changed chunks re-embed) → **Extractor** |
| stack n8n env / secrets | update `graphrag-workflows` env (Step 3.1) + `kubectl -n graphrag rollout restart deploy graphrag-workflows` |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Graph Modeling heartbeat **401** | `EXTRACTOR_AUTH` encoded with `echo` (trailing newline) | Re-encode with `printf 'user:pass' \| base64`; update env + roll out the stack n8n |
| Workflow can't see `$env.*` | env not set on the stack n8n | add it to `graphrag-workflows` env (Step 3.1) + `kubectl -n graphrag rollout restart deploy graphrag-workflows` |
| GraphDB load **400** "Illegal carriage return" | raw newline in a Turtle literal | already fixed in the workflows; re-import the latest JSON |
| Notebook: "Cannot reach Elasticsearch" | ES unreachable | confirm `esUrl` in Unstructured Ingest Config points to the in-cluster service |
| Unstructured Ingest re-embeds everything | cache missing/changed model | expected on first run / after model change; otherwise check `output/embeddings-cache.json` |
| Graph Modeling returns docs with no concepts | extraction model not rebuilt | Corpus → Rebuild Extraction Model |
| Extractor: `HTTP 400: Concept Index is empty for projectId …` (all calls fail → Aggregate aborts before DROP) | thesaurus not imported into **this** (new) project, or extraction model never built | Import `taxonomy.ttl` + `umls_condition_concepts.ttl` into the project whose ID is in `EXTRACTOR_PROJECT_ID`, then **Corpus → Rebuild Extraction Model**; re-run the Extractor |
| UMLS verify shows 0 concepts in named graph | wrong named-graph URI on import | re-import with exact `https://uts.nlm.nih.gov/metathesaurus/` |
| Chatbot **spins forever** on the first prompt | workflows not seeded, or an LLM credential is empty | load the seed (Step 3.2) + fill **Main LLM Model credentials**; restart n8n |
| Chatbot answers with **no sources** / empty retrieval | `vectorStorePreset` still `opensearch_native`, or `VECTOR_INDEX` unset | set `Configuration` → `elasticsearch_native` + `va-doc-chunks` (Step 10.2) |
| N8N Prune Database → **404** "resource not found" on executions | `n8n-nodes-base.n8n` node appends only `/executions` to the Base URL — `/api/v1` is not added automatically | Set the `n8n Internals` credential Base URL to `http://graphrag-workflows:5678/api/v1` (include `/api/v1`) — see Step 11.1 |
| Prune workflow runs but **nothing is deleted** | `Return All` not enabled — only the first page (~100 records) is fetched and deleted | Enable the **Return All** toggle on the `Get many executions` node — see Step 11.2 |

---

## Appendix — Re-generating the corpus (optional, not needed for the workshop)

The corpus is committed, so skip this unless you are updating the source data.
Open **`notebooks/Prepare-Source-Data.ipynb`** and run the sections in order:
scrape 38 CFR Parts 3 & 4 (~1 min each), download/extract the VA Presumptive PDF,
enumerate + scrape the M21-1 Manual (~45 min + 2–3 hours), extract the CSVs, and
extract the UMLS condition vocabulary (needs `UMLS_API_KEY`). All sections are
resumable.
