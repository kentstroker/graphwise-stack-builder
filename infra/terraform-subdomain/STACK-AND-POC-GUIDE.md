# Graphwise Stack Builder — Deployment & POC Guide
**INTERNAL USE ONLY** | v2.0.0 | Author: Kent Stroker

This guide combines two earlier documents into a single flow: **Part A** covers deploying the AWS stack (Terraform, EC2, KIND, Helm), and **Part B** covers running a customer POC on that stack once it is up. Read Part A once, then return to Part B for each engagement.

---

## Table of Contents

**Part A — Stack Deployment**
- [Kit Layout](#kit-layout)
- [Kit Scripts](#kit-scripts)
- [Laptop Prerequisites (one-time)](#laptop-prerequisites-one-time)
- [Deploy a New Stack](#deploy-a-new-stack)
- [After the Build: Pull Config](#after-the-build-pull-config)
- [Rebuild / Destroy-and-Rebuild Flow](#rebuild--destroy-and-rebuild-flow)
- [Auto-Shutdown and Restart](#auto-shutdown-and-restart)
- [Loading Staging Data](#loading-staging-data)
- [Stack Tear Down](#stack-tear-down)

**Part B — POC Setup**
- [Overview](#poc-overview)
- [Step 1 — Load GraphDB](#step-1--load-graphdb)
- [Step 2 — Load Graph Modeling](#step-2--load-graph-modeling)
- [Step 3 — Configure n8n (read this carefully)](#step-3--configure-n8n)
- [Step 4 — Structured Ingest](#step-4--structured-ingest)
- [Step 5 — Unstructured Ingest](#step-5--unstructured-ingest)
- [Step 6 — Annotate (Extractor)](#step-6--annotate-extractor)
- [Step 7–9 — Validate](#steps-7-9--validate)
- [Step 10 — Activate the Chatbot (optional)](#step-10--activate-the-chatbot-optional)
- [Step 11 — Prune n8n Execution History](#step-11--prune-n8n-execution-history)

**Reference**
- [Troubleshooting](#troubleshooting)
- [Kubernetes Dashboard and Grafana](#kubernetes-dashboard-and-grafana)

---

# Part A — Stack Deployment

## Kit Layout

The kit ships as `graphwise-stack-builder-kit-v2.0.0.tar.gz` — get it from Kent. It contains credentials and license keys valid for **internal Graphwise use only**. For customer-facing stacks, use proper 30-day licenses, not the internal kit licenses.

Files marked `[git-ignored]` are never committed — they are credentials, licenses, or Terraform run artifacts you supply or generate locally.

```
terraform-subdomain/                  (the kit root; copy this per stack)
├── DEPLOYMENT_GUIDE.md
├── QUICK-START.md
├── STACK-AND-POC-GUIDE.md            ← this file
│
├── main.tf                           EC2 + EIP + security group + IAM
├── variables.tf                      all input variables + defaults + descriptions
├── outputs.tf                        instance_id, public_ip, DNS names
├── versions.tf                       Terraform + provider version pins
├── user-data.sh.tpl                  cloud-init: preps host + optionally builds stack
├── terraform.tfvars.example          → copy to terraform.tfvars, fill in your values
│
├── terraform.tfvars                  [git-ignored] your subdomain, EIP, key pair, CIDR
├── graphwise-secrets.yaml            [git-ignored] maven, AWS Bedrock, n8n license/encryption
├── n8n.txt                           [git-ignored] AWS creds + extractor auth for workflow env
│
├── .terraform/                       [git-ignored] provider plugins (terraform init)
├── .terraform.lock.hcl               [git-ignored] provider lock file
├── terraform.tfstate                 [git-ignored] live state after apply
├── terraform.tfstate.backup          [git-ignored] previous state
│
├── files/
│   ├── n8n-pg-dumpall.sql.tar.gz     committed — known-good n8n workflow DB seed
│   ├── n8n-pg-dumpall.sql            [git-ignored] raw uncompressed dump (generated locally)
│   └── licenses/
│       ├── poolparty.key             [git-ignored] PoolParty license
│       ├── graphdb.license           [git-ignored] GraphDB EE license
│       └── uv-license.key            [git-ignored] UnifiedViews license
│
└── scripts/
    ├── check-prereqs.sh              macOS preflight: verifies toolchain + AWS auth
    ├── manage-stacks.sh              add/list/remove stack SSH entries in ~/.zprofile
    ├── stack-scp.sh                  scp wrapper using manage-stacks.sh key/host entries
    ├── pull-config.sh                save live secrets + wildcard cert from EC2 to laptop
    └── push-config.sh                push saved secrets + cert to a fresh EC2
```

---

## Kit Scripts

Run all scripts from your **per-stack Terraform folder** (e.g. `~/Desktop/terraform-kaiser/`), not from the git repo root.

---

### `check-prereqs.sh` — Laptop preflight

Read-only. Checks and reports — never changes anything. Run this before anything else on a fresh laptop or after an OS upgrade.

**What it checks:** macOS version, Homebrew, AWS CLI, Terraform, SSH, `dig`, `rsync`, AWS authentication, Python 3 + PyYAML, IDE presence.

```bash
cd ~/Desktop/terraform-kaiser
./scripts/check-prereqs.sh
```

All checks print ✓ (green), ! (warning), or ✗ (error). Fix every ✗ before proceeding.

---

### `manage-stacks.sh` — SSH multi-stack manager

Writes labelled blocks into `~/.zprofile` so you can SSH to any stack with a short alias. Each block exports `GW_KEY_<name>`, `GW_HOST_<name>`, and a configurable SSH alias. These variables are also read automatically by `stack-scp.sh`, `pull-config.sh`, and `push-config.sh`.

```bash
./scripts/manage-stacks.sh            # interactive menu
./scripts/manage-stacks.sh list       # print all configured stacks
./scripts/manage-stacks.sh add        # add a new stack (interactive prompts)
./scripts/manage-stacks.sh remove     # remove a stack (picker)
```

**Adding a stack:**
```bash
./scripts/manage-stacks.sh add
# Stack name:     kaiser
# Key file path:  ~/.ssh/kaiser-stack-key.pem
# Hostname:       kaiser.gw-pse.com
# Alias name:     sshkaiser   (press Enter for default)
```

After adding, open a new terminal or `source ~/.zprofile`, then:
```bash
sshkaiser    # → ssh -i ~/.ssh/kaiser-stack-key.pem ec2-user@kaiser.gw-pse.com
```

---

### `stack-scp.sh` — Authenticated file transfer

`scp` wrapper that reads key and host from `~/.zprofile`. Prefix EC2-side paths with `:`.

```bash
./scripts/stack-scp.sh [--stack <name>] [-r] <source> <dest>

# Push a file to the EC2
./scripts/stack-scp.sh logo.png :~/logo.png

# Pull a file from the EC2
./scripts/stack-scp.sh :~/wildcard-tls.yaml ./

# Recursive push
./scripts/stack-scp.sh -r ./data :~/staging-data/

# Named stack, skip picker
./scripts/stack-scp.sh --stack kaiser -r :~/gsb/files/ ./local-backup/
```

---

### `pull-config.sh` — Snapshot EC2 state to laptop

SSH to the EC2 and pull everything needed to survive a `terraform destroy`. **Run this before every destroy.**

What gets pulled:
- `graphwise-secrets.yaml` — rebuilt from live Kubernetes Secrets the pods are consuming
- License files: `poolparty.key`, `graphdb.license`, `uv-license.key`
- `licenses/wildcard-tls.yaml` — the live Let's Encrypt wildcard cert (saves a rate-limit slot on rebuild)
- `graphwise-stack-chart-values.yaml` + diff (drift detector)
- `dashboard-kubeconfig.yaml`

Everything lands in a timestamped folder in the current directory:
```
graphwise-config-kaiser.gw-pse.com-20260708T143012Z/
    graphwise-secrets.yaml
    graphwise-stack-chart-values.yaml
    graphwise-stack-chart-values.diff    (only if drift vs. git baseline)
    dashboard-kubeconfig.yaml
    licenses/
        poolparty.key
        graphdb.license
        uv-license.key
        wildcard-tls.yaml
```

```bash
cd ~/Desktop/terraform-kaiser
./scripts/pull-config.sh
```

If `manage-stacks.sh` was used, the script picks up `GW_KEY_*` / `GW_HOST_*` from `~/.zprofile` automatically. Otherwise pass them inline:
```bash
GRAPHWISE_KEY=~/.ssh/kaiser-stack-key.pem \
GRAPHWISE_HOST=kaiser.gw-pse.com \
./scripts/pull-config.sh
```

---

### `push-config.sh` — Restore snapshot to a fresh EC2

Sends the snapshot created by `pull-config.sh` back to a newly provisioned EC2. Run this **after `terraform apply` but before `cluster-bootstrap.sh`** on the EC2.

| Snapshot file | EC2 destination |
|---|---|
| `graphwise-secrets.yaml` | `~/graphwise-secrets.yaml` |
| `licenses/poolparty.key` | `~/gsb/files/licenses/` |
| `licenses/graphdb.license` | `~/gsb/files/licenses/` |
| `licenses/uv-license.key` | `~/gsb/files/licenses/` |
| `licenses/wildcard-tls.yaml` | `~/wildcard-tls-saved.yaml` |

The **n8n encryption key** is handled automatically: `push-config.sh` reads the fresh key Terraform wrote to the new EC2 and splices it into `graphwise-secrets.yaml` before pushing. The old key from the prior stack is not forwarded — the new database will use the new key.

```bash
cd ~/Desktop/terraform-kaiser
./scripts/push-config.sh                        # auto-discovers most recent snapshot
./scripts/push-config.sh --list                 # show available snapshots
./scripts/push-config.sh --snapshot ./graphwise-config-kaiser.gw-pse.com-20260708T143012Z
./scripts/push-config.sh --skip-cert            # force fresh LE issuance
```

---

## Laptop Prerequisites (one-time)

Your AWS PSE user account has already been created. You receive two CSV files with your Access Key ID and Secret Access Key.

**macOS — install toolchain:**
```bash
# Install Homebrew (skip if brew --version already works)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install awscli terraform         # ssh + dig ship with macOS
```

**Configure the AWS CLI:**
```bash
aws configure        # paste: Access Key ID, Secret, region us-west-2, output json
```

Or write the files directly:
```bash
mkdir -p ~/.aws && chmod 700 ~/.aws

cat > ~/.aws/credentials <<'EOF'
[default]
aws_access_key_id     = AKIA...your-key...
aws_secret_access_key = ...your-secret...
EOF

cat > ~/.aws/config <<'EOF'
[default]
region = us-west-2
output = json
EOF

chmod 600 ~/.aws/credentials ~/.aws/config
```

Verify:
```bash
aws sts get-caller-identity
```

Then confirm the full laptop toolchain is ready:
```bash
./scripts/check-prereqs.sh
```

**Create your EC2 key pair** (once — reuse across all stacks, or create one per stack):
```bash
aws ec2 create-key-pair --region us-west-2 --key-name {lastname}-stack-key \
  --query 'KeyMaterial' --output text > ~/.ssh/{lastname}-stack-key.pem
chmod 400 ~/.ssh/{lastname}-stack-key.pem
```

---

## Deploy a New Stack

> **AWS region:** Use `us-west-2` (Oregon). Other regions are not yet validated.

---

### Step 1 — Allocate an Elastic IP *(laptop)*

Each stack needs a static public IP. Allocate one per stack you intend to maintain.

```bash
aws ec2 allocate-address --domain vpc --region us-west-2
```

Save both the `PublicIp` (`<eip>`) and `AllocationId` (`eipalloc-…`) — you need both in later steps. The EIP survives `terraform destroy`/`apply` cycles, so DNS never needs re-pointing. If you permanently decommission a stack, release the EIP and remove the DNS records to stop charges.

---

### Step 2 — Add DNS records *(laptop / console)*

> **Shared Route 53 zone:** `gw-pse.com` — hosted zone ID `Z03476331NSJ3X9EZAGNE`. **Do not change this value in terraform.tfvars.**

Add two A records, both pointing at `<eip>`:

| Name | Type | Value |
|---|---|---|
| `<sub>.gw-pse.com` | A | `<eip>` |
| `*.<sub>.gw-pse.com` | A | `<eip>` |

Via CLI (`UPSERT` = create-or-update, safe to re-run):
```bash
SUB=<sub>
EIP=<eip>
ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='gw-pse.com.'].Id" --output text | sed 's|/hostedzone/||')

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "$(cat <<JSON
{
  "Comment": "graphwise stack $SUB",
  "Changes": [
    { "Action": "UPSERT", "ResourceRecordSet": {
        "Name": "$SUB.gw-pse.com", "Type": "A", "TTL": 300,
        "ResourceRecords": [ { "Value": "$EIP" } ] } },
    { "Action": "UPSERT", "ResourceRecordSet": {
        "Name": "*.$SUB.gw-pse.com", "Type": "A", "TTL": 300,
        "ResourceRecords": [ { "Value": "$EIP" } ] } }
  ]
}
JSON
)"
```

Verify propagation:
```bash
dig +short <sub>.gw-pse.com poolparty.<sub>.gw-pse.com    # both must print <eip>
```

DNS must be live **before** Terraform runs — cert-manager uses it for the wildcard certificate.

---

### Step 3 — Create the stack working folder *(laptop)*

Copy the kit folder, naming it for this stack:
```bash
cp -r infra/terraform-subdomain ~/Desktop/terraform-<sub>
cd ~/Desktop/terraform-<sub>
```

This folder is the home for everything about this stack: Terraform state, credentials, snapshots, and scripts. Run all subsequent steps from here.

---

### Step 4 — Edit `terraform.tfvars` *(laptop)*

Copy the example and fill in the required fields:
```bash
cp terraform.tfvars.example terraform.tfvars
```

```hcl
region                     = "us-west-2"
base_domain                = "gw-pse.com"
subdomain                  = "<sub>"
route53_zone_id            = "Z03476331NSJ3X9EZAGNE"
le_email                   = "you@graphwise.ai"
key_pair_name              = "{lastname}-stack-key"        # name only, no .pem
admin_cidr                 = "<your-ip>/32"                # curl -4 icanhazip.com
availability_zone          = "us-west-2a"
existing_eip_allocation_id = "eipalloc-…"                 # from Step 1
creator                    = "Your Name"
purpose                    = "Customer X presales demo"
```

---

### Step 5 — Fill in `graphwise-secrets.yaml` *(laptop)*

The kit ships with this file partially pre-filled with internal-use credentials. Open it and confirm or update as needed. The file structure:

```yaml
maven:
  user: <maven-username>          # provided in the kit
  pass: <maven-password>          # provided in the kit

graphrag-secrets:
  awsCredentials:
    region: us-west-2
    accessKeyId: AKIA...           # your AWS access key ID (from your CSV)
    secretAccessKey: ...           # your AWS secret access key

  n8nLicense:
    activationKey: ...             # provided in the kit

  n8nEncryption:
    key: ...                       # provided in the kit — DO NOT CHANGE
```

> **The `n8nEncryption.key` must remain constant** across rebuilds of the same subdomain. It is the key that encrypts all n8n credentials in the database. Changing it makes the existing database unreadable. The kit's value is correct — leave it alone. `push-config.sh` handles splicing the right key automatically on rebuild.

---

### Step 6 — Prepare `n8n.txt` *(laptop, for later use on EC2)*

`n8n.txt` holds the per-deployment credentials that get injected into the n8n workflow pod environment. You write this file **on the EC2** during the POC setup phase (Part B, Step 3.2), but it helps to have the values ready now.

Required fields:
```
AWS_ACCESS_KEY_ID=AKIA...           # your AWS access key (same as graphwise-secrets.yaml)
AWS_SECRET_ACCESS_KEY=...           # your AWS secret access key
EXTRACTOR_AUTH=Basic <base64>       # Graph Modeling superadmin credentials (see note)
EXTRACTOR_PROJECT_ID=<uuid>         # Graph Modeling project UUID — set after Step 2 in Part B
```

Generate `EXTRACTOR_AUTH` using `printf` (not `echo` — `echo` adds a trailing newline that causes 401 errors):
```bash
printf 'superadmin:corgiDAD#2' | base64
# Prefix the output: EXTRACTOR_AUTH=Basic <output>
```

> **`EXTRACTOR_PROJECT_ID`** is the UUID of the Graph Modeling project you create in Part B Step 2. You cannot fill this in until that project exists.

---

### Step 7 — Provision the EC2 *(laptop)*

```bash
cd ~/Desktop/terraform-<sub>
terraform init
terraform plan
terraform apply
```

Terraform creates the EC2, attaches the EIP, and starts cloud-init. The stack build continues automatically on the EC2. Monitor it:

```bash
ssh -i ~/.ssh/{lastname}-stack-key.pem ec2-user@<sub>.gw-pse.com
sudo tail -f /var/log/bootstrap.log
```

> **If this is a rebuild of an existing subdomain** and you ran `pull-config.sh` before destroying, **now is the time to run `push-config.sh`** from your laptop (before proceeding on the EC2). This restores the saved wildcard cert, avoiding a new Let's Encrypt issuance.

---

### Step 8 — Build the stack over SSH *(EC2)*

Wait for cloud-init to finish (check with `kubectl get nodes`), then run:

**Option A — Single script (after you have experience):**
```bash
cd ~/gsb
./scripts/deploy-stack.sh <sub> gw-pse.com
```

**Option B — Step by step (recommended until familiar):**
```bash
cd ~/gsb

./scripts/cluster-bootstrap.sh
# Wait: kubectl get pods -A — all pods running before continuing

./scripts/validate-bootstrap.sh
./scripts/extract-poolparty-realm.sh
./scripts/preflight-reset-helm.sh
./scripts/reset-helm.sh --yes <sub> gw-pse.com
# Wait: kubectl get pods -A — all 1/1 Running before continuing

./scripts/restore-n8n-dumpall.sh
./scripts/validate-stack.sh
```

Monitor pod status:
```bash
kubectl get pods -A        # one-shot
kubectl get pods -A -w     # live watch (Ctrl-C to exit)
```

> **Typical build time: 15–20 minutes.** Graph Modeling (PoolParty) is always the last pod to reach Running status.

---

### Step 9 — Verify the stack *(EC2)*

```bash
export APEX=<sub>.gw-pse.com
for h in $APEX poolparty.$APEX auth.$APEX graphdb.$APEX graphrag.$APEX; do
  printf '%-45s ' "$h"
  curl -s -o /dev/null -w 'http=%{http_code}\n' "https://$h/" --max-time 10
done
```

All services should return `http=200` or `http=302`. Then browse `https://<sub>.gw-pse.com` — the console landing page.

---

### Step 10 — Add customer logo (optional) *(laptop + EC2)*

```bash
# From laptop — upload the PNG
scp -i $GRAPHWISE_KEY logo.png $GRAPHWISE_USER@$GRAPHWISE_HOST:~/logo.png

# From EC2 — set the logo
cd ~/gsb
./scripts/set-logo.sh
```

Use a PNG with a transparent background — the console header is blue.

---

## After the Build: Pull Config

**Run this immediately after every successful stack build.** Let's Encrypt limits wildcard certificate issuance to 5 per week per domain. Saving the cert from the current build means the next rebuild reuses it, preserving your rate-limit allocation.

```bash
cd ~/Desktop/terraform-<sub>
./scripts/pull-config.sh
```

Add the stack to your SSH manager so you can use it conveniently going forward:
```bash
./scripts/manage-stacks.sh add
```

---

## Rebuild / Destroy-and-Rebuild Flow

```bash
# 1. Before destroying — snapshot secrets + cert
cd ~/Desktop/terraform-<sub>
./scripts/pull-config.sh

# 2. Destroy
terraform destroy

# 3. Rebuild
terraform apply

# 4. Restore snapshot before bootstrap (from laptop)
./scripts/push-config.sh

# 5. SSH to EC2 and continue the build
sshkaiser
# → cluster-bootstrap.sh → reset-helm.sh → restore-n8n-dumpall.sh → validate-stack.sh
```

> **The wildcard cert saved in step 1 is restored in step 4**, so cert-manager sees a valid cert already in place and skips the LE DNS-01 round trip. This is why `pull-config.sh` before destroy is so important.

---

## Auto-Shutdown and Restart

Each stack has a CloudWatch alarm that **stops the EC2** when CPU utilization stays below 5% for 8 consecutive hours. This guards against forgotten idle stacks accumulating charges.

To restart: use the AWS Console (EC2 → Instances → Start) or:
```bash
aws ec2 start-instances --region us-west-2 --instance-ids <instance-id>
```

On boot, a systemd unit (`graphwise-cluster-resume.service`) runs automatically and restores all workloads — no manual intervention needed. Allow ~5 minutes for all pods to reach Running status.

> **Disable auto-shutdown during demo days** to prevent an idle window between sessions from triggering a stop:
> set `auto_shutdown_enabled = false` in `terraform.tfvars` and `terraform apply`.

---

## Loading Staging Data *(laptop)*

The EC2's `~/staging-data/` folder is mounted into the KIND cluster as a PVC, making it available to pods. Use it to stage data files for ingest workflows.

```bash
scp -r -i $GRAPHWISE_KEY {source_folder} $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/
```

After uploading, fix permissions so the n8n pod (different UID) can read and write:
```bash
# On the EC2
chmod -R a+rwX ~/staging-data/
```

---

## Stack Tear Down *(laptop)*

`terraform destroy` deletes the EC2 and its EBS volume — **all stack data is lost** (PoolParty projects, GraphDB repos, Keycloak users, n8n workflows, ingested documents). The EIP and DNS records survive because they are pre-allocated.

> **Always run `pull-config.sh` before destroying** if you plan to rebuild the same subdomain.

```bash
cd ~/Desktop/terraform-<sub>
./scripts/pull-config.sh      # save secrets + cert
terraform destroy
```

If the stack is being permanently decommissioned: release the EIP and delete the two Route 53 A records to stop charges.

---

---

# Part B — POC Setup

## POC Overview

Part B assumes the stack is already running (Part A complete, `validate-stack.sh` passing). The steps here load data, configure the workflow engine, run ingestion pipelines, and validate the knowledge graph before activating the chatbot.

The workflow engine (n8n) is the most operationally complex component — it spans multiple steps and has a lifecycle that is easy to misunderstand. Read the [n8n lifecycle box](#n8n-lifecycle-three-things-to-understand) at the start of Step 3 before touching anything n8n-related.

---

## Step 1 — Load GraphDB

**Create the repository.** In the GraphDB Workbench, go to **Setup → Repositories → Create new repository → GraphDB Repository**:

- **Repository ID:** `<project-repo-id>` (e.g. `va-benefits`)
- **Ruleset:** **OWL-Max (Optimized)**
- **Supports context index:** ✅ enabled
- **Enable full-text search (NLP):** ✅ enabled

Make it the **active repository** (click the pin/connect icon) before importing. Enable **Setup → Autocomplete** — GraphDB's MCP server requires it.

Import in order:

| # | File | Target graph |
|---|---|---|
| 1 | `modeling/ontology.ttl` | *default graph* |
| 2 | `modeling/taxonomy.ttl` | *default graph* |
| 3 | `modeling/schema.ttl` | *default graph* |
|

---

## Step 2 — Load Graph Modeling

**First-time login.** Sign in with `superadmin` / `poolparty`. Set the password to `corgiDAD#2` when prompted (the rest of the runbook and stack config assume this value).

**Create the project.** Create a new project named for your POC and **note its UUID** — you need it for `EXTRACTOR_PROJECT_ID` in `n8n.txt` (Step 3.2).

Import in order:

| # | File | Import type |
|---|---|---|
| 1 | `modeling/ontology.ttl` | Ontology |
| 2 | `modeling/taxonomy.ttl` | Thesaurus |
| 3 | `modeling/schema.ttl` | Project container |

Then: **Corpus → Rebuild Extraction Model** and wait for it to complete before running the Extractor. Skipping this leaves the concept index empty — every Extractor call will fail with `HTTP 400: Concept Index is empty`.

**Connect Graph Modeling to GraphDB.** Go to **Systems → Graph Databases → GraphDB → Create** and set the URL:
```
https://graphdb-projects.<sub>.gw-pse.com/repositories/<project-repo-id>
```

---

## Step 3 — Configure n8n

### n8n Lifecycle — Three Things to Understand

Before touching anything n8n-related, understand these three distinct phases. Mixing them up is the main source of confusion.

---

**Phase 1 — Database restore (stack build, already done)**

`restore-n8n-dumpall.sh` was run in Part A Step 8. It wiped the blank database and loaded the known-good seed, which contains all ~31 pre-built workflows plus the credential slots (filled with placeholder values). This happens once per stack build.

The restore produces a working n8n install with workflows intact. **You do not re-run this** unless you are resetting to a clean baseline.

---

**Phase 2 — Encryption key (managed automatically)**

Every n8n instance encrypts its stored credentials with `N8N_ENCRYPTION_KEY`. This key is generated by Terraform at EC2 creation and written into the Kubernetes Secret. **It must stay constant for the lifetime of the database** — if it changes, all stored credentials become unreadable garbage.

`push-config.sh` handles this automatically during rebuilds: it reads the fresh key from the new EC2 and splices the correct value into `graphwise-secrets.yaml` before pushing. You do not need to manage this manually. Just do not manually change `N8N_ENCRYPTION_KEY` anywhere.

---

**Phase 3 — Per-build and per-POC configuration (you do this now)**

After every restore, four things need to be done before n8n workflows will run:

1. **Kubernetes Secret** — write `~/n8n.txt` on the EC2 and create `n8n-poc-creds` Secret
2. **Environment injection** — patch the n8n Deployment with the Secret's values + behavior flags
3. **API key rotation** — the JWT stored in the database is stale after restore; generate a new one
4. **Configuration node** — update the four deployment-specific URLs/IDs in the `Configuration` workflow

These steps are detailed below.

---

### 3.1 — Restore the n8n database

Already done during the stack build (`restore-n8n-dumpall.sh`). Confirm the pod is up:

```bash
kubectl -n graphrag rollout status deploy/graphrag-workflows
```

If you need to reset n8n to the clean seed at any point:
```bash
cd ~/gsb
./scripts/restore-n8n-dumpall.sh
kubectl -n graphrag rollout status deploy/graphrag-workflows
```

---

### 3.2 — Write `~/n8n.txt` and create the Kubernetes Secret *(EC2)*

Now that you have the Graph Modeling project UUID from Step 2, write `~/n8n.txt` on the **EC2**:

```bash
cat > ~/n8n.txt <<'EOF'
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
EXTRACTOR_AUTH=Basic <base64-of-superadmin:corgiDAD#2>
EXTRACTOR_PROJECT_ID=<your-graph-modeling-project-uuid>
EOF
```

Generate `EXTRACTOR_AUTH` (use `printf`, not `echo`):
```bash
printf 'superadmin:corgiDAD#2' | base64
```

Create the Kubernetes Secret:
```bash
kubectl -n graphrag create secret generic n8n-poc-creds --from-env-file="$HOME/n8n.txt"
```

If the Secret already exists from a prior run:
```bash
kubectl -n graphrag delete secret n8n-poc-creds
kubectl -n graphrag create secret generic n8n-poc-creds --from-env-file="$HOME/n8n.txt"
```

> **After a `terraform destroy` and rebuild**, the Secret is gone (it lived in the cluster). You must re-create it from `~/n8n.txt` every time. Keep `~/n8n.txt` on the EC2 or re-push it with `stack-scp.sh`.

---

### 3.3 — Inject environment variables into the n8n Deployment *(EC2)*

Two commands — run both:

```bash
# Inject the credentials from the Secret
kubectl -n graphrag set env deploy/graphrag-workflows --from=secret/n8n-poc-creds

# Inject behavior flags that allow workflow code nodes to function
kubectl -n graphrag set env deploy/graphrag-workflows \
  N8N_BLOCK_ENV_ACCESS_IN_NODE=false \
  NODE_FUNCTION_ALLOW_BUILTIN='*' \
  NODE_FUNCTION_ALLOW_EXTERNAL=js-tiktoken \
  N8N_ALLOW_CODE_NODE_EXTERNAL_FILES=true \
  N8N_RUNNERS_TASK_TIMEOUT=1800 \
  N8N_RUNNERS_HEARTBEAT_INTERVAL=600

kubectl -n graphrag rollout status deploy/graphrag-workflows
```

| Flag | Why |
|---|---|
| `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` | lets nodes read `{{ $env.* }}`; without it the Configuration node fails |
| `NODE_FUNCTION_ALLOW_BUILTIN=*` | Code nodes may `require()` Node built-ins |
| `NODE_FUNCTION_ALLOW_EXTERNAL=js-tiktoken` | Unstructured Ingest's token-accurate chunker |
| `N8N_ALLOW_CODE_NODE_EXTERNAL_FILES=true` | Code-node file access |
| `N8N_RUNNERS_TASK_TIMEOUT=1800` | long corpus runs (~30 min) do not get killed |
| `N8N_RUNNERS_HEARTBEAT_INTERVAL=600` | headroom for large documents |

> **These patches are wiped by `helm upgrade`.** Re-run both `kubectl set env` commands any time `reset-helm.sh` is run.

---

### 3.4 — Log in to the n8n UI

Open `https://graphrag.<sub>.gw-pse.com` and log in:
- **Email:** `kent.stroker@graphwise.ai`
- **Password:** `graphDB#1`

Confirm the workflows list is populated (~31 workflows) and the `Main` workflow exists.

---

### 3.5 — Rotate the API key *(n8n UI)*

The database restore brings in a JWT that was valid on the source instance but is invalid here. It must be rotated before any workflow can make internal API calls. **The same rotated key is used in two credentials** — generate it once, then wire it into both.

**Generate the new key:**

1. n8n UI → **Settings → API** → delete the existing `graphwise-graphrag` key
2. Create a new key named `graphwise-graphrag` — **copy the value immediately** (shown only once)

**Update the `API_KEYS` Data Table** — this is the step most commonly missed:

n8n UI → **Data Tables → API_KEYS** → open the `N8N` row → paste the new key into `value` → save

> The data table is what workflow nodes read at runtime — not the credential objects. Skipping this step leaves the old (now-invalid) JWT in the table, causing every internal API call to return 401, silently in some nodes.

**Create or update the `graphwise-graphrag` credential** (used by most workflow HTTP Request nodes):

n8n UI → **Credentials → New → n8n API**:

| Field | Value |
|---|---|
| Name | `graphwise-graphrag` |
| API Key | the value copied above |
| Base URL | `http://graphrag-workflows:5678` |

**Create or update the `n8n Internals` credential** (used by the N8N Prune Database workflow — the node type does not append `/api/v1` itself, so the Base URL must include it):

n8n UI → **Credentials → New → n8n API**:

| Field | Value |
|---|---|
| Name | `n8n Internals` |
| API Key | the same value copied above |
| Base URL | `http://graphrag-workflows:5678/api/v1` |

> **Both credentials use the same API key** — the only difference is the Base URL suffix. If you later rotate the key again (e.g. after another restore), update the key in both credentials and in the `API_KEYS` data table row.

---

### 3.6 — Fill n8n credentials *(n8n UI)*

Go to n8n UI → **Credentials**. After a restore with a constant encryption key the blobs may already be populated — verify first and skip what is already filled.

**Main LLM Model credentials** (type: AWS):

| Field | Value |
|---|---|
| Access Key ID | `AWS_ACCESS_KEY_ID` from `~/n8n.txt` |
| Secret Access Key | `AWS_SECRET_ACCESS_KEY` from `~/n8n.txt` |
| Region | `us-west-2` |

**PoolParty Credentials** (type: HTTP Basic Auth):

| Field | Value |
|---|---|
| Username | `superadmin` |
| Password | `corgiDAD#2` |

**Keycloak clientId / clientSecret** (type: HTTP Basic Auth):

| Field | Value |
|---|---|
| Username | `conversation-api-client` |
| Password | Keycloak admin → realm `graphrag` → Clients → `conversation-api-client` → Credentials tab |

> The Keycloak client secret is **generated per stack build** — it differs each time. Always retrieve it from Keycloak admin. If wrong, the JWT token verification sub-workflow returns `{"active": false}` and the chatbot silently rejects every request.

---

### 3.7 — Edit the Configuration node *(n8n UI)*

Open the **`Configuration`** workflow from the workflows list, then open its **Code node**. This object drives the chatbot and conversation flows. The three ingest workflows (Structured, Unstructured, Extractor) have their own separate Config nodes — those are edited in Steps 4–6.

**Fields to change (infrastructure-specific):**

| Field | Seed value | Set to |
|---|---|---|
| `graphDBMcpUrl` | `https://graphdb-projects.kaiser.gw-pse.com/mcp` | `https://graphdb-projects.<sub>.gw-pse.com/mcp` |
| `graphDBMcpRepository` | `"coverage"` | your GraphDB repository name |
| `keycloakUrl` | `https://auth.kaiser.gw-pse.com` | `https://auth.<sub>.gw-pse.com` |
| `poolPartyServerUrl` | `https://poolparty.kaiser.gw-pse.com` | `https://poolparty.<sub>.gw-pse.com` |
| `poolPartyProjectId` | `"20670b0b-0ae0-42b1-ae0e-cf11c01ffac3"` | your PoolParty project UUID (from Step 2) |

**Fields to confirm match your POC (must be consistent with ingest workflows):**

| Field | Default | Notes |
|---|---|---|
| `vectorIndex` | `"doc-chunks"` | must match `esIndex` in Unstructured Ingest Config |
| `embeddingsModelId` | `"amazon.titan-embed-text-v2:0"` | must byte-match `embedModelId` in Unstructured Ingest — kNN fails if they differ |
| `mcpLLMModel` | `"us.anthropic.claude-sonnet-4-6"` | Bedrock inference profile ID |
| `primaryLLMModel` | `"us.anthropic.claude-sonnet-4-6"` | Bedrock inference profile ID |
| `secondaryLLMModel` | `"us.anthropic.claude-haiku-4-5-20251001-v1:0"` | Bedrock inference profile ID |

**Stable — do NOT change (internal k8s service names, same across all gsb deployments):**
- `backendUrl`: `http://graphrag-conversation:8080`
- `graphRagComponentsUrl`: `http://graphrag-components:8080`
- `internalN8nUrl`: `http://graphrag-workflows:5678`
- `embeddingsProvider`: `"aws"` (change only if switching to OpenAI)
- `vectorStorePreset`: `"elasticsearch_native"`

---

### 3.8 — Stage data files *(laptop)*

Copy the `output/` tree to the EC2:

```bash
scp -r -i "$GRAPHWISE_KEY" output "$GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/"
```

Fix permissions on the EC2 so the n8n pod (different UID) can read:
```bash
chmod -R a+rwX ~/staging-data/output
```

---

### 3.9 — Mount the staging PVC into the n8n pod *(EC2)*

```bash
CNAME=$(kubectl -n graphrag get deploy graphrag-workflows \
  -o jsonpath='{.spec.template.spec.containers[0].name}')

kubectl -n graphrag patch deploy graphrag-workflows --type=strategic -p \
  "{\"spec\":{\"template\":{\"spec\":{
    \"volumes\":[{\"name\":\"staging\",\"persistentVolumeClaim\":{\"claimName\":\"staging-data\"}}],
    \"containers\":[{\"name\":\"$CNAME\",\"volumeMounts\":[{\"name\":\"staging\",\"mountPath\":\"/data/staging\"}]}]
  }}}}"

kubectl -n graphrag rollout status deploy/graphrag-workflows

# Confirm the files are visible
kubectl -n graphrag exec deploy/graphrag-workflows -- ls /data/staging/output/csv | head
```

> **This mount is also wiped by `helm upgrade`.** Re-apply the patch if `reset-helm.sh` is run.

---

## Step 4 — Structured Ingest *(n8n)*

> **Note:** The seeded workflow is configured for a specific prior dataset. The ontology namespace, graph URIs, CSV column mappings, SPARQL class names, and expected record counts will all need adjusting to match your dataset's structure. Treat the seed as a working template, not a ready-to-run workflow.

In the stack n8n, **Import from File** `n8n-workflows/Structured Ingest.json`.

**`Config` node (Set node) — edit these fields:**

| Field | Seed value | Set to |
|---|---|---|
| `graphdb` | `https://graphdb-projects.va-benefits.gw-pse.com/repositories/va-benefits/statements` | `https://graphdb-projects.<sub>.gw-pse.com/repositories/<repo-id>/statements` |
| `poolparty` | `https://poolparty.va-benefits.gw-pse.com/extractor/api/tag` | `https://poolparty.<sub>.gw-pse.com/extractor/api/tag` |
| `annotationGraph` | `https://va-benefits.example/kg/annotations/` | your project's annotation graph URI |
| `csvDir` | `/data/staging/output/csv` | adjust only if your staging path differs |
| `rdfDir` | `/data/staging/output/rdf` | adjust only if your staging path differs |
| `prefixes` block | all use `va-benefits.example` namespace | your project's ontology namespace URIs |

> `extractorProjectId` and `extractorAuth` are already `{{ $env.EXTRACTOR_PROJECT_ID }}` / `{{ $env.EXTRACTOR_AUTH }}` env var references — no change needed.

**`Verify: SPARQL Counts` node (Code node) — edit if your ontology differs:**

This node runs SPARQL COUNT queries to assert minimum record thresholds after ingest. The class names and expected counts are VA-specific — replace with classes from your ontology and appropriate counts:

```
vak:DiagnosticCode ≥ 720,  vak:RatingCriterion ≥ 1331,  vak:PresumptiveCondition ≥ 200 ...
```

The `PREFIX vak:` declaration inside this node is also hardcoded to `https://va-benefits.example/kg/ontology#` — update it to match your ontology prefix.

Execute the workflow. It converts CSVs into typed graph nodes and loads them into GraphDB. Concept tagging happens later in Step 6.

---

## Step 5 — Unstructured Ingest *(n8n)*

> **Note:** The seeded workflow is configured for a specific prior dataset. The chunk graph URI, ontology namespace, Elasticsearch index name, and embedding model must all match your project's choices — and must stay consistent with the Extractor workflow (Step 6) and the Configuration node (Step 3.7). Review every Config field before running.

**Import from File** `n8n-workflows/Unstructured Ingest.json`.

**`Config` node (Set node) — edit these fields:**

| Field | Seed value | Set to |
|---|---|---|
| `graphdb` | `https://graphdb-projects.kaiser.gw-pse.com/repositories/coverage/statements` | `https://graphdb-projects.<sub>.gw-pse.com/repositories/<repo-id>/statements` |
| `esIndex` | `"doc-chunks"` | keep or choose your own name — **must match `vectorIndex` in Configuration (Step 3.7)** |
| `embedModelId` | `"amazon.titan-embed-text-v2:0"` | your Bedrock embedding model — **must byte-match `embeddingsModelId` in Configuration** |
| `embedRegion` | `"us-west-2"` | your AWS region |
| `chunksGraph` | `"https://kp.poolparty.biz/kg/chunks/"` | your chunk graph URI — **must match `chunksGraph` in Extractor Config (Step 6)** |
| `prefixes` block | uses `kp.poolparty.biz` namespace | your project's ontology namespace URIs |

> `awsAccessKeyId` and `awsSecretAccessKey` are already env var references — no change needed.
>
> `esUrl` (`http://graphwise-stack-poolparty-elasticsearch.graphwise:9200`) is the in-cluster Elasticsearch service — **stable across all gsb deployments, do not change**.

Execute the workflow. It reads the staged corpus, chunks each document, embeds with AWS Bedrock Titan v2, writes vectors to Elasticsearch, and writes chunk nodes into GraphDB.

> - **If the Elasticsearch index already exists from a prior run with a different mapping**, delete it first: `curl -X DELETE http://graphwise-stack-poolparty-elasticsearch.graphwise:9200/<esIndex>` (run from inside a pod, or use `kubectl port-forward`).
> - Embeddings are cached to `output/embeddings-cache.json` — re-runs reuse cached vectors for unchanged text.
> - If you get `ENOENT … /data/staging/output/...`, the staging PVC is not mounted — redo Step 3.9.

---

## Step 6 — Annotate (Extractor) *(n8n)*

> **Note:** The seeded workflow is configured for a specific prior dataset. The annotation graph URIs, ontology namespace, chunk graph URI, and PoolParty concept base URI are all dataset-specific — and unlike the other workflows, several of these are hardcoded directly in Code and HTTP Request nodes rather than in the Config node alone. Review and update all six nodes listed below before running.

**Import from File** `n8n-workflows/Extractor.json`.

> **This workflow has hardcoded values in six different nodes.** Edit all of them before running — partial edits leave stale URIs in the graph.

---

**Node 1 — `Config` (Set node):**

| Field | Seed value | Set to |
|---|---|---|
| `graphdb` | `https://graphdb-projects.kaiser.gw-pse.com/repositories/coverage/statements` | `https://graphdb-projects.<sub>.gw-pse.com/repositories/<repo-id>/statements` |
| `poolparty` | `https://poolparty.kaiser.gw-pse.com/extractor/api/tag` | `https://poolparty.<sub>.gw-pse.com/extractor/api/tag` |
| `annotationGraph` | `"https://kp.poolparty.biz/kg/annotations/"` | your annotation graph URI |
| `chunkAnnotationGraph` | `"https://kp.poolparty.biz/kg/chunk-annotations/"` | your chunk annotation graph URI |
| `chunksGraph` | `"https://kp.poolparty.biz/kg/chunks/"` | must match `chunksGraph` in Unstructured Ingest |

---

**Node 2 — `Test: PoolParty Heartbeat` (HTTP Request node) — URL field is hardcoded, does NOT read from Config:**
```
https://poolparty.kaiser.gw-pse.com/extractor/api/heartbeat
```
Change to: `https://poolparty.<sub>.gw-pse.com/extractor/api/heartbeat`

---

**Node 3 — `Drop: Both Annotation Graphs` (HTTP Request node) — SPARQL body is hardcoded:**

The request body contains:
```sparql
DROP SILENT GRAPH <https://kp.poolparty.biz/kg/annotations/> ;
DROP SILENT GRAPH <https://kp.poolparty.biz/kg/chunk-annotations/>
```

Replace both URIs to match your `annotationGraph` and `chunkAnnotationGraph` from Node 1.

---

**Node 4 — `Query: All Text Nodes` (HTTP Request node) — SPARQL body is hardcoded:**

The SPARQL contains:
```sparql
?node <https://kp.poolparty.biz/kg/ontology#chunkText> ?text .
```

Change `https://kp.poolparty.biz/kg/ontology#chunkText` to `{your-ontology-prefix}chunkText`.

---

**Node 5 — `Extract + Load: Chunks` (Code node) — three hardcoded items:**

1. **`KP_BASE`** constant — the base URI of concepts PoolParty returns in extraction results. This comes from the PoolParty **project's own Base URI setting**, not the infrastructure subdomain. Get it from PoolParty → your project → Settings → Base URI:
   ```js
   const KP_BASE = 'https://kpd.poolparty.biz/';  // ← change this
   ```

2. **`encodeURIComponent()`** call inside `loadToGraphDB()` — this ignores `cfg.chunkAnnotationGraph` and hardcodes the URI:
   ```js
   encodeURIComponent('<https://kp.poolparty.biz/kg/chunk-annotations/>')  // ← change this
   ```
   Change to match your `chunkAnnotationGraph`.

3. **RDF triple predicate** — hardcoded in the triple-building string:
   ```js
   <https://kp.poolparty.biz/kg/ontology#hasConcept>  // ← change this
   ```
   Change to match your ontology's concept relation predicate.

---

**Node 6 — `Verify: Annotation Counts` (Code node) — graph URIs and prefix hardcoded:**

```js
const GRAPHS = {
  structured: 'https://kp.poolparty.biz/kg/annotations/',       // ← change
  chunks:     'https://kp.poolparty.biz/kg/chunk-annotations/'  // ← change
};
const PREFIX = 'PREFIX kpkg: <https://kp.poolparty.biz/kg/ontology#>';  // ← change
```

None of these read from the Config node. Update all three to match your URIs.

---

Execute the workflow. One run tags both the structured nodes and the chunks, writing concept-relation triples into GraphDB. It drops and rebuilds both annotation graphs each run — safe to re-run when the taxonomy or extraction model changes.

---

## Cross-workflow Consistency Requirements

Seven values must be consistent across multiple workflows. Set them once in one place, then copy to the others — inconsistency here causes silent failures (kNN misses, empty annotation graphs, 401s).

| Value | Set in | Must match in |
|---|---|---|
| `esIndex` / `vectorIndex` | Unstructured Ingest Config | Configuration Code node |
| `embedModelId` / `embeddingsModelId` | Unstructured Ingest Config | Configuration Code node — kNN breaks if these differ even by whitespace |
| `chunksGraph` | Unstructured Ingest Config | Extractor Config |
| `annotationGraph` | Extractor Config | Extractor "Drop" node body, Extractor "Verify" GRAPHS object |
| `chunkAnnotationGraph` | Extractor Config | Extractor "Drop" node body, Extractor "Extract+Load" `encodeURIComponent()` call, Extractor "Verify" GRAPHS object |
| Ontology namespace URI | Structured Ingest prefixes + SPARQL Counts | Unstructured Ingest prefixes, Extractor "Query Text" SPARQL, Extractor "Extract+Load" triple predicate, Extractor "Verify" PREFIX |
| PoolParty concept base URI (`KP_BASE`) | Extractor "Extract+Load" Code node | PoolParty project Base URI setting — **get the value FROM PoolParty, not the other way around** |

---

## Steps 7–9 — Validate

> **Note:** The notebooks referenced here are from a prior dataset and will not run against your data without modification. They are included to illustrate the validation *approach* — how to use SPARQL queries and GraphDB's Workbench to confirm that the ontology is loaded, triples are well-formed, Extractor annotations are landing in the correct graphs, embeddings are present, and kNN retrieval is returning semantically grounded results. Adapt the SPARQL and assertions to your own ontology classes, graph URIs, and expected record counts before running.
>
> **These steps save time.** Catching a missing annotation graph, a mismatched embedding model, or an empty vector index here — at the GraphDB/SPARQL level — costs minutes. Discovering the same problem after activating the chatbot costs hours of tracing silent failures through the GraphRAG pipeline. Resolve data quality issues at this layer before proceeding to Step 10.

**Step 7 — Validate the structured graph:**
Open `notebooks/Structured-Validate-GraphDB.ipynb` and run all cells. Confirms ontology, taxonomy, structured nodes, and Extractor annotations all loaded correctly into the expected named graphs.

**Step 8 — Validate the unstructured graph:**
Open `notebooks/Unstructured-Validate-GraphDB.ipynb` and run all cells. Validates chunk nodes, embeddings, Elasticsearch index field mapping, and GraphRAG readiness (should show **READY ✓** in the final cell).

**Step 9 — Validate GraphRAG retrieval:**
Open `notebooks/GraphRAG-Prompt-Validation.ipynb` and run all cells. Puts real questions through the same two retrieval paths the chatbot uses — concept-layer SPARQL + vector kNN — and surfaces the grounding evidence you should expect to see cited in chatbot answers.

---

## Step 10 — Activate the Chatbot

All 28 chatbot workflows were pre-seeded by the n8n database restore. With the graph and vector store now populated and validated, three steps bring the chatbot online:

1. Confirm all credentials in **Credentials** are filled (Step 3.6)
2. Confirm the **Configuration** node has the correct deployment values (Step 3.7)
3. **Activate** the `Main` workflow (toggle the activation switch)

**Smoke test:**
Ask *"How does VA establish service connection for a disability?"* — it should return a grounded, cited answer in around 90 seconds or less.

- **Hangs forever:** workflows not seeded, or an LLM credential is empty
- **Returns no sources:** `vectorStorePreset` is wrong, or `vectorIndex` doesn't match the actual Elasticsearch index

> **LLM model IDs must be Bedrock inference profile IDs** (e.g. `us.anthropic.claude-sonnet-4-6`) — bare foundation-model IDs return `InvalidRequestException`. All three LLM slots in `Configuration` should use the same profile ID.

---

## Step 11 — Prune n8n Execution History (maintenance)

Execution records accumulate quickly during active ingest runs and slow the n8n UI. The **N8N Prune Database** workflow deletes them. It may already be present in the seeded database; if not, **Import from File** `n8n-workflows/cleanup.json`.

The `n8n Internals` credential was created in Step 3.5. Assign it to both the **Get many executions** and **Delete an execution** nodes in this workflow.

In the **Get many executions** node, enable **Return All** — without it only the first ~100 records are fetched.

In **Set Executions to Keep**, set `executionsToKeep` to `0` to purge everything, or a positive integer to keep that many recent records per workflow. Then execute the workflow.

---

## Re-run Reference

| What changed | Action |
|---|---|
| CSV / structured source data | Re-run Structured Ingest, then Extractor |
| Taxonomy or extraction model | Rebuild Extraction Model in Graph Modeling, then re-run Extractor |
| Source documents | Re-run Unstructured Ingest → Extractor |
| `helm upgrade` / `reset-helm.sh` ran | Re-run Steps 3.3 and 3.9 (env injection + PVC mount were wiped) |
| Stack rebuilt (destroy → apply) | Full Part B from Step 3.2 (Secret gone, env gone, API key stale) |

---

---

# Troubleshooting

## Pod Status

```bash
kubectl get pods -A            # one-shot snapshot
kubectl get pods -A -w         # live watch (Ctrl-C to exit)
kubectl get pods -n graphwise
kubectl get pods -n graphrag
kubectl get pods -n keycloak
kubectl get pods -n cert-manager
```

## Bootstrap Log

```bash
ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST
sudo tail -f /var/log/bootstrap.log
```

## Pod Logs

```bash
kubectl logs -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name> -f          # stream live
kubectl logs -n <namespace> <pod-name> --tail=100
kubectl logs -n <namespace> <pod-name> --previous  # after crash-loop
```

Find the pod name by app:
```bash
kubectl get pods -n graphwise | grep poolparty
```

## Kubernetes Events

Often more useful than logs for startup failures:
```bash
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

## TLS Certificate Issues

Let's Encrypt limits wildcard cert issuance to **5 per week per domain**. If you hit the limit or ended up with a staging cert, delete the Secret — cert-manager immediately requests a fresh production cert:

```bash
kubectl delete secret wildcard-tls -n cert-manager
```

Monitor progress:
```bash
kubectl get certificate wildcard-tls -n cert-manager -w
kubectl get order,challenge -n cert-manager
kubectl describe order -n cert-manager | tail -30
kubectl logs -n cert-manager deploy/cert-manager --tail=40 2>&1 | grep -iE 'error|denied|challenge|dns'
```

> **Why staging certs break the stack:** PoolParty's JVM validates the full TLS chain when connecting to Keycloak at startup. The Let's Encrypt staging chain is not trusted by the JVM's default trust store, so the OIDC handshake fails and PoolParty never reaches Ready. Always use `letsencrypt-prod`.

## n8n Workflow Issues

| Symptom | Likely cause | Fix |
|---|---|---|
| Workflow can't read `$env.*` | env not injected or wiped by helm upgrade | Re-run Step 3.3 + `kubectl -n graphrag rollout restart deploy/graphrag-workflows` |
| Internal API calls return 401 | API key not rotated or not updated in Data Table | Redo Step 3.5 |
| Graph Modeling heartbeat 401 | `EXTRACTOR_AUTH` was `echo`-encoded (trailing newline) | Re-encode with `printf`, re-create the Secret (Step 3.2), re-inject env (Step 3.3) |
| Extractor: `HTTP 400: Concept Index is empty` | Extraction model not rebuilt after thesaurus import | Graph Modeling → Corpus → Rebuild Extraction Model |
| Unstructured Ingest: ENOENT on staging files | Staging PVC not mounted (wiped by helm upgrade) | Re-run Step 3.9 |
| N8N Prune → 404 "resource not found" | `n8n Internals` credential missing `/api/v1` in Base URL | Set Base URL to `http://graphrag-workflows:5678/api/v1` (Step 11) |
| Chatbot spins forever | Workflows not seeded, or LLM credential empty | Confirm restore ran; fill Main LLM Model credentials (Step 3.6) |
| Chatbot answers with no sources | `vectorStorePreset` wrong or `vectorIndex` mismatch | Set `elasticsearch_native` + correct index name in Configuration node (Step 3.7) |

---

# Kubernetes Dashboard and Grafana

## Kubernetes Dashboard

The `dashboard-kubeconfig.yaml` file in your `pull-config.sh` snapshot is the authentication file for the Kubernetes Dashboard. When you open the dashboard from the console landing page, choose the **file** method and upload this file.

Each stack generates its own bearer token — the kubeconfig from one stack does not work on another.

## Grafana

Access Grafana from the console landing page. Credentials are shown on the panel. The underlying Prometheus collects full cluster metrics from the KIND stack. Graphwise-specific dashboard recipes (GraphDB query latency, PoolParty heap, etc.) are planned for a future release.
