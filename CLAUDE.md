# CLAUDE.md

**Maintainer:** Kent Stroker

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It is the spine — the *rules* and live state live here; the *narratives* (rationale, full Job templates, walkthroughs) live under `docs/claude/`. **`docs/` is now gitignored (local-only, never pushed), so treat CLAUDE.md as the self-contained record** — the `→ docs/claude/*.md` pointers below resolve only in the maintainer's local checkout.

## What this repo is

A **Helm-on-KIND** deployment of the Ontotext / Graphwise **PoolParty** ecosystem plus the **GraphRAG** chatbot suite, on a single **AWS EC2** instance (Amazon Linux 2023, Docker, single-node KIND cluster). All ingress is HTTPS via ingress-nginx + cert-manager + Let's Encrypt. It is explicitly a **demo / evaluation** deployment — not production-ready — see the warning block in [DEPLOY.md](DEPLOY.md) for the full list of what would need to change for production use.

**Audience and licensing.** Primarily for **internal use by Graphwise field presales engineers**. Public (MIT-licensed, AS-IS, no warranty, no support — see [LICENSE](LICENSE)) so that customers, partners, and the semantic-web community can reference it when building their own evaluation environments. External users must supply their own Graphwise license files (PoolParty/GraphDB EE/UnifiedViews — obtained by contacting Graphwise), their own AWS account, and their own domain. The repo ships zero license files and no access to Graphwise's shared presales domain `semantic-demo.com`.

**OS history.** Previously deployed on Debian 13 with rootless podman. Migrated to AL2023 + Docker in late 2026 after consistent "ssh fails immediately after scp" failures on Debian 13 + AWS Nitro that nobody could explain; AL2023 doesn't trigger the issue. KIND on Docker is also better-supported (KIND-on-podman is still `KIND_EXPERIMENTAL_PROVIDER`).

## Layout

No application source code is in this repo. Only:

- `infra/kind/kind-config.yaml` — single-node KIND cluster definition
- `infra/terraform-<stack>/` — provisions an EC2 host pre-loaded with kind/kubectl/helm and a running cluster
- `charts/graphwise-stack/` — umbrella Helm chart (PoolParty + GraphDB ×2 + addons + console + Keycloak + supporting graphrag Secrets/Postgres)
- `charts/{poolparty,graphdb,addons,console,poolparty-elasticsearch,keycloak-realms}/` — per-app sub-charts
- `charts/vendor/graphrag*/` — vendored GraphRAG charts (chatbot, conversation, components, workflows) — installed as a separate Helm release
- Helper scripts under `scripts/` (EC2-side) and `infra/terraform-subdomain/scripts/` (laptop-side: `pull-config.sh`, `push-config.sh`, `manage-stacks.sh`, `stack-scp.sh`, `check-prereqs.sh`) — see `docs/claude/scripts.md`
- Vendor license files under `files/licenses/` (gitignored)

Changes are usually to a chart's `values.yaml` / `templates/`, the umbrella's `templates/`, or `scripts/render-values.sh`.

**Companion docs:** [STACK-BUILDER.md](STACK-BUILDER.md) (complete operator guide — architecture, setup, deploy, day-2 lifecycle, URLs/credentials), [infra/TERRAFORM_NOTES.md](TERRAFORM_NOTES.md) (Terraform module reference), [infra/terraform-subdomain/DEPLOYMENT_GUIDE.md](infra/terraform-subdomain/DEPLOYMENT_GUIDE.md) (PSE SE full-stack deploy walkthrough).

## Architecture in one paragraph

The Helm path runs as **two separate releases**: `graphwise-stack` (in `graphwise` ns — PoolParty, GraphDB ×2, ES, console, addons, Keycloak CR + Postgres + realm imports, **plus** the supporting Secrets/ConfigMap/Postgres the GraphRAG pods need, materialized in the `graphrag` namespace) and `graphrag` (in `graphrag` ns — vendored chatbot/conversation/components/workflows pods from `charts/vendor/graphrag/`, installed as its own release because the vendor templates don't set `metadata.namespace` and would otherwise land in `graphwise` where they can't mount the supporting Secrets).

**Order matters.** Install: umbrella first (creates Secrets/Postgres in `graphrag`), then graphrag. Uninstall: graphrag first (so pods release mounts/connections), then umbrella. `scripts/reset-helm.sh` enforces both.

## Subdomain-per-app routing

Each app gets its own subdomain so ingress-nginx can mint a separate cert per app and each app's webapp doesn't need a context-path-prefix story:

| App | Hostname |
|---|---|
| Console (landing) | `<sub>.<base>` (apex) |
| Keycloak | `auth.<sub>.<base>` |
| PoolParty | `poolparty.<sub>.<base>` |
| GraphDB embedded | `graphdb.<sub>.<base>` |
| GraphDB projects | `graphdb-projects.<sub>.<base>` |
| ADF | `adf.<sub>.<base>` |
| Semantic Workbench | `semantic-workbench.<sub>.<base>` |
| GraphViews | `graphviews.<sub>.<base>` |
| RDF4J | `rdf4j.<sub>.<base>` |
| UnifiedViews | `unifiedviews.<sub>.<base>` |
| Ontotext Refine | `refine.<sub>.<base>` (CIDR-allowlisted via `admin_cidr`) |
| GraphRAG (chatbot + conversation + workflows) | `graphrag.<sub>.<base>` (different paths) |
| Kubernetes Dashboard | `dashboard.<sub>.<base>` |
| Prometheus | `prometheus.<sub>.<base>` |
| Grafana | `grafana.<sub>.<base>` |

DNS needs both `<sub>.<base>` (apex) and `*.<sub>.<base>` (wildcard) A-records to the EIP. The Terraform module's `route53_dns_records` output prints both. **EIP must be pre-allocated** via `existing_eip_allocation_id` in `terraform.tfvars` so it survives `terraform destroy`/`apply` cycles — see `docs/claude/aws-and-terraform.md`.

## Critical rules (the ones that cause stack breakage)

- **Keycloak hostname must be exactly `auth.<sub>.<base>` with `strict: true` on the CR** (NO `/auth` path). Spring Security's `NimbusJwtDecoder.withIssuerLocation()` is strict-equality on the issuer URL; any drift kills every OIDC client at boot. The operator-generated Ingress lacks a `tls:` block when `httpEnabled: true`, so we set `spec.ingress.enabled: false` on the CR and ship our own Ingress with the TLS block. → `docs/claude/keycloak.md`

- **PoolParty `llm.model` is duplicated across TWO chart layers** (`charts/poolparty/values.yaml` and `charts/graphwise-stack/values.yaml`); umbrella wins. Grep `claude\|llama\|nova` across `charts/` before any LLM-config edit. Newer Bedrock chat models (Llama 3.3+, Claude Sonnet 3.5 v2+, Nova, Mistral Large 2) need an **inference profile ID** (`us.` / `eu.` / `apac.` prefix) — bare foundation-model IDs return `InvalidRequestException`. Secret-only updates require a manual `kubectl rollout restart` — `secretKeyRef` env vars are snapshotted at pod start. → `docs/claude/poolparty-llm.md`

- **GraphDB JVM heap is set explicitly** to `-Xmx8g` (memory limit `10Gi`) in `charts/graphdb/values.yaml`. Without `-Xmx`, the JVM defaults to ~1Gi regardless of pod limit and `GROUP BY` / `DISTINCT` queries fail with `Insufficient free Heap Memory`. **Rule of thumb: heap = pod memory limit − 2Gi.**

- **Nested-subchart `.tgz` is gitignored** (`charts/*/charts/*.tgz` + `charts/*/Chart.lock`). Committing them creates the silent-stale-tarball footgun: Helm prefers the tarball over source edits, so chart changes silently no-op. The umbrella's own `charts/graphwise-stack/charts/*.tgz` IS committed (vendored deps, intentional). If you see addons resources missing expected fields after an edit, suspect this — `rm charts/addons/charts/*.tgz charts/addons/Chart.lock` then `helm dependency update`.

- **GraphDB subchart fullname must keep `.Chart.Name`** in the helper (`printf "%s-%s" .Release.Name .Chart.Name`). The umbrella installs `charts/graphdb/` twice as aliases (`graphdb-embedded`, `graphdb-projects`); dropping `.Chart.Name` collapses them into one manifest and later aliases silently overwrite earlier ones. PoolParty's `internalUrl` (`http://graphwise-stack-graphdb-embedded:7200`) depends on the prefixed name. → `docs/claude/chart-internals.md`

- **TLS: one wildcard cert via Route 53 DNS-01**, reflector mirrors it into every consuming namespace. Every Ingress's `tls.secretName: wildcard-tls`. `letsencrypt-prod` only — staging chain isn't trusted by in-cluster JVM clients (PoolParty → Keycloak), TLS handshake fails. → `docs/claude/tls-and-ingress.md`

- **Two-IAM-user actor model** (AWS). `terraform-demo` (laptop, infra provisioning) and `graphrag-bedrock` (runtime, baked into Secret). All IAM creation done by root or IAM-admin, NEVER by `terraform-demo` itself. EIP must be pre-allocated via `existing_eip_allocation_id` (required). AMI is locked via `lifecycle.ignore_changes` + `ami_override` to prevent `terraform apply` from destroying the EC2 when AWS publishes an AL2023 refresh. → `docs/claude/aws-and-terraform.md`

- **Mac → EC2 sync during iteration**: edits land on Mac, `scp` to EC2 before `helm upgrade`. Git is intentionally not in the loop until changes settle. `helm get manifest graphwise-stack -n graphwise` confirms what was actually applied — useful when an expected change isn't taking effect.

- **Default password convention: `rdf#rocks`** for chart-default passwords (Keycloak/n8n/conversation Postgres, ingress basic-auth, conversation Keycloak client secret). Exceptions: `keycloak.bootstrapAdmin.password = "admin"` (PoolParty's chart hard-codes it), `n8nEncryption.key` (auto-generated by Terraform), Grafana `demo-graphwise-2026` (historic).

## Lifecycle scripts (one-liners)

Full descriptions in `docs/claude/scripts.md`.

- `scripts/cluster-bootstrap.sh` — one-time install of cluster operators + observability (ingress-nginx, cert-manager + LE issuer, CNPG, Keycloak operator, metrics-server, Dashboard, kube-prometheus-stack).
- `scripts/cluster-resume.sh` — restart KIND nodes after EC2 stop/start; sets `--restart=unless-stopped`; then calls `cluster-start.sh` to auto-restore any workloads `cluster-stop.sh` scaled down. Run on every boot by the `graphwise-cluster-resume.service` systemd unit, so the stack survives a reboot hands-off.
- `scripts/cluster-stop.sh` — quiesce app workloads (scale-to-0) before stopping the EC2. Records each workload's prior replica count in the `graphwise.ai/replicas-before-stop` annotation (only when >0, so re-runs don't clobber it) for `cluster-start.sh` to read back.
- `scripts/cluster-start.sh` — symmetric partner to `cluster-stop.sh`: scales the `graphwise`/`graphrag` Deployments+StatefulSets back to their pre-stop replica counts from the annotation, then clears it. Annotation-gated, so it only touches what `cluster-stop.sh` scaled and is a no-op otherwise. Auto-invoked at the end of `cluster-resume.sh`.
- `scripts/render-values.sh` — emit `$HOME/.graphwise-stack/values-<sub>.yaml` + `$HOME/.graphwise-stack/values-<sub>-graphrag.yaml`. Auto-invoked by `reset-helm.sh`. (Persistent across reboots; AL2023 wipes `/tmp` on boot, so the prior `/tmp` location was a footgun after `cluster-stop.sh` → start.)
- `scripts/install-licenses.sh` — create the three license Secrets in `graphwise` ns from `files/licenses/`.
- `scripts/preflight-reset-helm.sh` — read-only pre-flight gate (tools, cluster, operators, DNS, IMDS, maven auth probe).
- `scripts/validate-bootstrap.sh` — post-bootstrap health check.
- `scripts/validate-stack.sh` — post-reset-helm.sh health check (pods, certs, OIDC issuers, HTTPS reachability).
- `scripts/reset-helm.sh [--yes] [--skip-graphrag] <subdomain> [base_domain]` — wipe and reinstall both releases.
- `infra/terraform-subdomain/scripts/{pull,push}-config.sh` — symmetric snapshot pair for `~/graphwise-secrets.yaml` + licenses + live wildcard cert. Default snapshot directory is `$(pwd)` — run from the per-stack terraform folder (e.g. `~/Desktop/terraform-kstroker/`). The saved wildcard cert lets `cluster-bootstrap.sh` skip LE DNS-01 re-issuance on rebuild (rate-limit preservation).
- `scripts/check-image-versions.sh` — laptop-side: compare all chart image tags against Docker Hub latest, display a table, and offer interactive upgrades. Pass `--yes` to apply all. Rebuilds umbrella tarballs after any change.
- `infra/terraform-subdomain/scripts/manage-stacks.sh` — add/list/remove Graphwise stack SSH entries in `~/.zprofile` as sentinel-delimited blocks (`# --- GW stack: <name> ---`). Each block writes `GW_KEY_<name>`, `GW_HOST_<name>`, and an alias whose name is user-configurable at add time (default `ssh<name>`). Subcommands: `list`, `add`, `remove`, or interactive menu.
- `infra/terraform-subdomain/scripts/stack-scp.sh` — scp wrapper that auto-fills `-i <key>` and `ec2-user@<host>:` from the `~/.zprofile` blocks written by `manage-stacks.sh`. Prefix EC2-side paths with `:` (e.g. `:~/file.txt`). Supports `-r` (recursive), `--stack <name>` (skip picker). Bash 3.2 compat: uses `${SCP_FLAGS[@]+"${SCP_FLAGS[@]}"}` guard for empty array under `set -u`.

## Chart internals — pointers

Detail in `docs/claude/chart-internals.md`:

- GraphDB subchart fullname pattern (alias-aware) + namespace split (`graphdb-embedded` in `graphwise`, `graphdb-projects` in `graphdb`).
- GraphDB JVM heap rationale (`-Xmx8g` / limit `10Gi`).
- Staging-data three-layer wiring (`/home/ec2-user/staging-data/` → KIND `extraMounts` → PVC per namespace).
- Console landing page Helm `tpl` pattern.
- UnifiedViews `uv-password-reset` Job (SPARQL-resets admin/admin via RDF4J in-cluster).
- `graphrag-vectors-index` Job (PUTs the Elasticsearch index graphrag-components's health probe requires).
- KIND lifecycle on EC2.
- Default password convention details.

Keycloak-specific Jobs (authz-import, graphrag-realm-patch, bootstrap-admin race fix) are in `docs/claude/keycloak.md`.

## Resolved bug catalog

Patterns to recognize when something looks familiar — full write-ups in `docs/claude/bug-history.md`:

- PoolParty stuck on Keycloak `uma2-configuration` → realm export `${...}` placeholders not substituted.
- `unifiedviews` `CrashLoopBackOff` → stale nested-subchart `.tgz` shadowed the source initContainer fix.
- GraphDB subchart fullname collision under umbrella aliases.
- `graphrag-realm-patch` `BackoffLimitExceeded` on cold-cache → race with realm-import + Keycloak v26 role-model change.
- **Version-string collision** — a bump target that equals another component's *current* version (e.g. PoolParty→10.2.2 while UnifiedViews is still 10.2.2). A global `sed` cross-contaminates; grep the OLD string per-file and change deliberately.
- **Console `logoAlt` not HTML-escaped** — a customer name with `& < > "` breaks the `<img alt>` attribute. Fixed by HTML-escaping in the console template (a `replace` chain, `&` first) AND keeping the `set-logo.sh` overlay YAML valid (escape `"`).
- **`helm --set` mis-parses commas** in a base64 data URI (`--set branding.logoDataUri=data:…,AAAA` splits on the comma). Use a values FILE, never `--set`, for anything with commas.
- **`check-prereqs.sh` IDE detection false-negative** — one `ls -d /Applications/PyCharm*.app /Applications/IntelliJ*.app …` exits non-zero if ANY glob misses, so a present PyCharm went undetected. Fixed with a LaunchServices lookup: `osascript -e 'id of app "PyCharm"'` (finds the app wherever installed, incl. JetBrains Toolbox, without launching it).
- **License leak on a folder rename** — the ignore was anchored (`files/licenses/*.key`), so renaming `files/`→`files.master/` re-exposed the blobs. Fixed with depth-agnostic `**/licenses/*` + `!**/licenses/README.txt` — no parent-dir rename can leak them.
- **n8n DB restore from a `pg_dumpall`** — the dump has no `--clean`, so the existing `n8n` DB must be `DROP DATABASE n8n WITH (FORCE)`-ed first or old artifacts survive; `postgres`/`streaming_replica` roles already exist (CNPG-managed) so their `CREATE ROLE` lines error harmlessly; re-assert `ALTER ROLE n8n PASSWORD 'rdf#rocks'` + `public` grants after. Restored credentials only decrypt if n8n boots with the **same `N8N_ENCRYPTION_KEY`** (kept constant in `n8n.txt`).
- **Wrong `route53_zone_id` → cert-manager DNS-01 `AccessDenied`** — `variables.tf` validation regex `^Z[A-Z0-9]+$` accepts any well-formed-but-wrong zone ID (including stale values from other accounts or a placeholder). The EC2 instance role's IAM policy is created by Terraform but scoped to the wrong hosted-zone ARN, so cert-manager's `ChangeResourceRecordSets` on the real zone returns `AccessDenied`. Wildcard cert never issues; everything depending on Keycloak OIDC fails at startup. Symptom: `kubectl describe challenge -n cert-manager` shows `Failed to change Route53 record … AccessDenied`. Fix: (1) get the real zone ID — `aws route53 list-hosted-zones --query 'HostedZones[?Name==\`<base_domain>.\`].Id' --output text | sed 's|/hostedzone/||'`; (2) patch the live role without a rebuild — `aws iam put-role-policy --role-name <role> --policy-name graphwise-stack-route53 --policy-document <corrected-json>`; cert-manager retries automatically on its exponential backoff. Correct `terraform.tfvars` for the next `terraform apply`. Do NOT trust the validation regex to catch wrong IDs.
- **macOS bash 3.2 empty array under `set -u`** — bash 3.2 (macOS built-in) treats `${arr[@]}` as unbound when the array is empty under `set -u`, even though the array was declared. Idiomatic fix: `${arr[@]+"${arr[@]}"}` — the outer `+` guard expands to nothing when empty instead of erroring. First surfaced in `stack-scp.sh` when `-r` or other flags were not passed (empty `SCP_FLAGS` array). Every macOS-targeted script using `set -u` + arrays requires this guard.

## Release history — v1.2.x → the 2.0.0 flatten

Git history will be squashed to a single commit at the **2.0.0 flatten** (repo
already renamed `graphwise-stack` → `graphwise-stack-builder`, on-disk folder `gsb`;
see the local `docs/superpowers/` flatten note). The "what/why" of the 1.2.x and
1.3.x lines is recorded here so it survives the squash:

- **v1.2.0 (GA)** — **Federated demo databases**: a standalone **Postgres** (CNPG `Cluster`) and **MySQL** (`StatefulSet`, `mysql:9.7`, no operator) in a new **`federated`** namespace — infra-only, in-cluster access only (no Ingress/cert/SG) — for demonstrating GraphDB federation against the projects instance. **AdeptNova** (the 3rd, public-`:17200` GraphDB) fully retired across charts/Terraform/KIND/scripts/docs; **GraphDB is now ×2**. Image bumps: PoolParty 10.2.2, console nginx 1.31.2, UnifiedViews 10.2.3.
- **Console features** — a **Full Stack ↔ Demo Mode** toggle (header pill; Demo shows only Graph Modeling, Extractor REST, GraphDB — projects, GraphRAG Chatbot; persisted in `localStorage['gw-console-mode']`), and **customer-logo branding** via `scripts/set-logo.sh` (base64 data-URI → a gitignored `console-branding.yaml` overlay that `reset-helm.sh` includes; graceful default is the Graphwise logo). `logoAlt` is HTML-escaped in the template.
- **v1.2.1** — patch rev (chart `version:` + the four stack-marker `appVersion`s → 1.2.1; product appVersions unchanged).
- **One-folder deploy (`gsb`)** — **`infra/terraform-subdomain/`** is the single folder a teammate downloads: the module, laptop scripts (`scripts/` — `check-prereqs.sh` macOS preflight, `terraform-deploy.sh`, push/pull-config, terraform-destroy), a **`USER_GUIDE.md`**, licenses/logo/secrets, and the n8n DB. Teammates run `check-prereqs.sh` → edit `user-data.sh.tpl` build mode (manual default) → `init`/`plan` → **`terraform-deploy.sh` (NOT `terraform apply`)** → build → watch `kubectl get pods -A` (~10-15 min) → browser.
- **n8n DB delivery + restore** — the known-good workflow DB ships as a **gzip tarball** (`infra/terraform-subdomain/files/n8n-pg-dumpall-*.sql.tar.gz`, ~18MB) because the raw `.sql` is 138MB (> GitHub's 100MB limit); `user-data.sh.tpl` expands it to `$HOME` at cloud-init. The n8n **Configuration** workflow's `poolPartyProjectId` + GraphDB paths MUST be set to your deployment or every ingest workflow fails.
- **Security + hygiene** — SSH (22), HTTP (80), and HTTPS (443) all locked to **`var.admin_cidr`**. LE cert issuance and renewal are unaffected — the ClusterIssuer uses DNS-01 via Route 53 exclusively; no inbound port is required. Every raw direct port stays bound to `127.0.0.1` inside the instance. **Existing stacks**: `terraform apply` won't update SG rules due to `lifecycle { ignore_changes = [ingress] }` — update the port 80 and 443 rules manually via the AWS Console (change source from `0.0.0.0/0` to `admin_cidr`). `.gitignore` hardened: license blobs ignored in **any** `licenses/` dir; all terraform run artifacts (state/lock/backup/plan/tfvars) ignored anywhere; **`docs/`, `n8n-workflows/`, `files.master/` are local-only** (delivered out-of-band, never pushed).

**v1.3.x (pre-GA 2.0.0 iteration):**
- `infra/README.md` renamed → `infra/TERRAFORM_NOTES.md`; all in-repo links updated.
- `infra/terraform-subdomain/scripts/manage-stacks.sh` (new) — SSH multi-stack manager with sentinel blocks in `~/.zprofile`; alias name configurable at `add` time.
- `infra/terraform-subdomain/scripts/stack-scp.sh` (new) — scp wrapper reading key/host from `~/.zprofile` blocks; `:path` prefix for EC2 side; bash 3.2 array compat.
- `pull-config.sh` / `push-config.sh` — default snapshot dir changed `~/Downloads` → `$(pwd)` so snapshots land in the terraform working folder.
- Documentation consolidation (GA 2.0.0): `QUICKSTART.md`, `SETUP.md`, `DEPLOY.md`, `HOWITWORKS.md`, `CONSOLE-GUIDE.md`, `AMI-OPS.md`, `NEW-STACK.md` merged into single `README.md`; `infra/TERRAFORM_NOTES.md` rewritten to focus on Terraform module internals + `user-data.sh.tpl`; old files deleted.
- **HTTP/HTTPS locked to `admin_cidr`** — ports 80 and 443 SG rules changed from `0.0.0.0/0` to `var.admin_cidr`. Safe because the ClusterIssuer is DNS-01 (Route 53) — no inbound port needed for LE cert issuance or renewal. Existing stacks: update port 80/443 SG rules manually via AWS Console (Terraform's `ignore_changes = [ingress]` blocks apply).

**v2.1.0 (post-2.0.0 GA) — minor rev bundling image bumps + console branding + workflow-seed refactor:**
- **Image bumps** (from `scripts/check-image-versions.sh` findings): GraphDB `11.4.0→11.4.1`, ADF `1.8.2→1.9.0`, Semantic Workbench `2.4.2→2.5.0`, GraphViews `1.0.0→1.0.1`. Each addon subchart's `appVersion` was updated to match its new tag — a step `check-image-versions.sh`'s `apply_addon_update` skips (it touches only `values.yaml`), so those were hand-edited to preserve the `appVersion == image tag` invariant. Applied per-file (grep the OLD string), never a global `sed`, per the version-string-collision rule.
- **Version rev → 2.1.0**: all chart `version:` fields (umbrella + every subchart + dependency `version:` refs) and the four stack-marker `appVersion`s (`graphwise-stack`, `addons`, `keycloak-realms`, `console`) bumped `2.0.0→2.1.0`; **product appVersions unchanged**. Umbrella tarballs rebuilt via `helm dependency update` (`charts/graphwise-stack/charts/*-2.0.0.tgz` → `*-2.1.0.tgz`).
- **Console landing-page branding alignment**: palette moved to Graphwise brand colors (`#00107F`/`#0011FF`/`#3399F0` blues + `#DF367C` magenta accent) replacing the generic blues; per-product logos added to the "Start here" cards (`charts/console/files/*300.png`, re-keyed in the ConfigMap to URL-safe filenames because the source names contain spaces); cards relabelled to Graphwise product names (Workflows(n8n)→**Graph Automation**, Extractor REST→**Semantic Analytics**, GraphDB—projects→**GraphDB**, GraphRAG Chatbot→**GraphRAG**).
- **Workflow DB seed refactor (drop "n8n" from filenames)**: `restore-n8n-dumpall.sh` → `restore-workflows-dumpall.sh`, `create-n8n-dumpall.sh` → `create-workflows-dumpall.sh`. The seed is **no longer shipped in the repo/clone** — it lives only on the EC2 home root as `$HOME/workflows-pg-dumpall-<date>-v<N>.sql` (scp'd up by the operator, or produced by `create-workflows-dumpall.sh`); `restore-workflows-dumpall.sh` loads the **NEWEST** by version sort and is a no-op if none present (**no fallback to the clone**). `.gitignore` now blocks `**/workflows-pg-dumpall*.sql` + `**/n8n-pg-dumpall*.sql` repo-wide. Only the seed file + script names dropped "n8n"; the K8s/Postgres object names (`graphrag-postgres-n8n` cluster, `graphrag-workflows` deploy, the `n8n` DB/role, `graphrag-n8n-*` secrets) are unchanged. Refs updated: `deploy-stack.sh`, `validate-stack.sh`, `STACK-BUILDER.md` (formerly `README.md`), `TERRAFORM_NOTES.md`.

## Currently open issues (Helm path)

- *(Resolved 2026-05-28 via bundled platform-independent dist)* **Refine `ontotext/refine:1.2.2` is amd64-only on Docker Hub** (`manifest.v2`, no manifest-list). On Graviton (arm64) the vendor's image CrashLoopBackOffs with `exec /opt/ontorefine/dist/bin/ontorefine: exec format error`. Workaround: the **extracted platform-independent dist is checked into the repo** at `refine/ontorefine-1.2.1/` (Java only, 180 JARs, no native binaries — `bin/ontorefine` is a bash launcher that `exec`s java). `scripts/build-refine-image.sh` wraps it in `eclipse-temurin:11-jre` (multi-arch, picks up arm64 natively) and `kind load`s it as `graphwise-refine:local`. `cluster-bootstrap.sh` auto-runs the build; `scripts/render-values.sh` auto-emits `addons.refine.enabled: true` + the local-image override in the per-deploy overlay when the dist directory is detected. Chart defaults (`refine.enabled: false` in both `charts/graphwise-stack/values.yaml` and `charts/addons/values.yaml`) are the safety net for sparse-checkout / shallow-clone edge cases. Source `.zip` is gitignored (153 MB single file exceeds GitHub's 100 MB per-file hard limit); the extracted dir's largest JAR is well under. Remove this entry once Graphwise publishes a multi-arch tag of `ontotext/refine` -- at that point flip defaults to `enabled: true`, repository back to `ontotext/refine`, delete the bundled dist, and remove the dist-detection plumbing.

- *(Resolved 2026-05-28, kept here as a note for the next deploy)* **PoolParty Keycloak post-deploy user creation** used to 500 with `skosView is missing` / INTERNAL ERROR because (a) the realm referenced PoolParty's SPI + theme that ship inside `ontotext/poolparty-keycloak` and weren't on stock Keycloak's classpath, and (b) the realm's `default-roles-poolparty` composite didn't include any role that satisfies the `ppt` client's UMA policies for locally-created users. Fixed by: (1) pinning `KEYCLOAK_OPERATOR_VERSION=25.0.6` in `cluster-bootstrap.sh` and pointing the Keycloak CR at `ontotext/poolparty-keycloak:latest` directly (`spec.image` + `startOptimized: false`) via the new `keycloak.image` values knob — KIND pre-loads the vendor image during bootstrap, so the SPI + theme load natively; (2) `charts/keycloak-realms/templates/poolparty-default-roles-patch-job.yaml` — post-install/upgrade Job that composes `PoolPartyUser` into `default-roles-poolparty` so every new user is auto-authorized at creation. Verified end-to-end on a fresh destroy/apply: brand-new Keycloak admin-console user lands in PoolParty's projects list with no manual role granting. If the symptom ever returns, suspect the operator vs server version pin (KC 25 SPI doesn't load in KC 26) or the realm export changing the role hierarchy (a different role might be required — `defaultUserRole` in `keycloak-realms` values is the knob).
