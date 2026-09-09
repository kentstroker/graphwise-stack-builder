# Laptop Kit — Deploy a Graphwise Stack

A step-by-step walkthrough for going from "I have the repo" to "I have a running
stack": what to install on your laptop, what AWS and DNS setup happens before
Terraform ever runs, how to provision and connect, and how to keep the stack
running day to day.

For architecture, the full app URL / credential table, chart internals, and a
troubleshooting runbook, see **[STACK-BUILDER.md](STACK-BUILDER.md)** — this
guide gets you to a running stack; that one is the reference you keep coming
back to.

---

## 1. What the kit is

Everything here runs on **your laptop**. The stack itself — GraphDB, Graph
Modeling (PoolParty), Elasticsearch, Keycloak, n8n, and the GraphRAG chat suite
— runs on a single AWS EC2 instance, and arrives there automatically via
cloud-init when Terraform provisions it. You never hand-copy the Helm charts or
the EC2-side scripts; `git clone` on the EC2 (triggered by cloud-init) does that.

The kit lives at [`laptop-kit/`](../laptop-kit/) in this repo, in three parts:

- **`terraform-aws/`** — the Terraform module that provisions the EC2 host, and
  its 8 helper scripts (§ [Kit script reference](#11-kit-script-reference)).
- **`skills/`** — a Claude Code skill (`creating-poolparty-ttl`) for authoring
  PoolParty-compatible SKOS taxonomy/ontology Turtle files, used once you're
  modeling data on the running stack.
- **An n8n workflow seed** (`n8n_db_script_v.1.1.0.sql`) — the official baseline
  GraphRAG chat workflows, described further in § [Deploy](#9-deploy).

Scripts under [`scripts/`](../scripts/) at the repo root are a separate thing:
they run **on the EC2**, not your laptop, and arrive there via the same
cloud-init clone — you don't invoke them directly until you're SSHed in.

---

## 2. Getting the kit

Two ways to get the repo onto your laptop:

- **Release asset** — download `laptop-kit-3.0.0.zip` from this repo's
  [Releases](https://github.com/kentstroker/graphwise-stack-builder/releases)
  page and unzip it. Smallest and simplest if you don't need git history.
- **Shallow clone** — if you want the full repo (including the charts and
  scripts that cloud-init pulls onto the EC2 for you):

  ```bash
  git clone --depth 1 https://github.com/kentstroker/graphwise-stack-builder.git
  ```

  `--depth 1` matters here: a full clone is ~151 MB of history, a depth-1 clone
  is ~2 MB. You don't need the history to deploy.

All commands below assume you're working from a checkout of this repo, in
`laptop-kit/terraform-aws/`.

---

## 3. Prerequisites

You'll need:

- An AWS account you can create IAM users and resources in.
- A domain whose DNS is hosted in a Route 53 zone you control (cert-manager
  needs to write `_acme-challenge` TXT records there for the wildcard cert).
- Graphwise licenses — `poolparty.key`, `graphdb.license`, `uv-license.key`,
  and Maven registry credentials — from `support@graphwise.ai`. These are
  per-partner; nothing is shipped in this repo.

Full IAM setup (the two-actor model, exact policies) is covered in
[STACK-BUILDER.md § Prerequisites](STACK-BUILDER.md) — read that
before your first deploy. Once your toolchain (Homebrew, AWS CLI, Terraform,
`dig`, `jq`, …) is installed, verify it from `laptop-kit/terraform-aws/`:

```bash
./scripts/check-prereqs.sh
```

It's read-only — checks and reports, changes nothing. Fix every `✗` before
continuing.

---

## 4. AWS prep

Two things must exist **before** `terraform apply` — cert-manager needs live
DNS to complete the wildcard-cert challenge, and the EIP has to be known so DNS
can point at it:

1. **Pre-allocate an Elastic IP** and note both the `AllocationId` and the
   `PublicIp`:

   ```bash
   aws ec2 allocate-address --domain vpc --region <region>
   ```

2. **Create two Route 53 A records**, both pointing at that IP — the apex
   `<sub>.<base_domain>` and the wildcard `*.<sub>.<base_domain>`. Verify
   propagation before moving on:

   ```bash
   dig +short <sub>.<base_domain> poolparty.<sub>.<base_domain>
   # both lines should print the EIP
   ```

---

## 5. Configure

From `laptop-kit/terraform-aws/`:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set, at minimum: `subdomain`, `base_domain`,
`route53_zone_id`, `admin_cidr` (your laptop's public IP, `/32` — never
`0.0.0.0/0`), `le_email`, and `existing_eip_allocation_id` (from step 4).

The `extra_tags` block (org compliance tags) ships correct in the example file
— **don't edit those values**.

Licenses and secrets (`graphwise-secrets.yaml`, the license files) are **not**
part of `terraform.tfvars` — they're supplied out-of-band and delivered to the
EC2 separately, in § [Push config](#8-push-config) below.

---

## 6. Provision

```bash
terraform init
terraform plan       # read this — a handful of resources to create
terraform apply
```

This creates the EC2, attaches the EIP, and kicks off cloud-init, which
installs Docker + KIND + kubectl + Helm and clones this repo onto the instance.

**Terraform safety rule:** after this first apply, never run an unscoped
`terraform apply` again without reading `terraform plan` in full first — an AMI
refresh can force-replace the instance and destroy its data. Lock the AMI
immediately after your first successful apply; see
[STACK-BUILDER.md § Provisioning and bootstrap](STACK-BUILDER.md)
for the exact steps.

---

## 7. Connect

Register the stack for a short SSH alias, then use it:

```bash
./scripts/manage-stacks.sh add
# prompts for a name, the .pem path, the hostname, and an alias
source ~/.zprofile     # or open a new terminal
ssh<name>
```

Once connected, tail the bootstrap log until cloud-init finishes:

```bash
sudo tail -f /var/log/bootstrap.log
# wait for: === Bootstrap complete === , then Ctrl-C
```

Give it a couple of minutes after `terraform apply` before your first SSH
attempt — cloud-init is still setting up the login shell.

---

## 8. Push config

Your Graphwise licenses and secrets (Maven credentials, AWS Bedrock keys, the
n8n Enterprise key) need to reach the EC2. `push-config.sh` delivers them in
one SSH round trip.

**First build:** copy `graphwise-secrets.example.yaml` to a working copy (e.g.
`~/graphwise-secrets.yaml`) and fill in your Maven credentials and AWS Bedrock
keys — leave `n8nEncryption.key` untouched, it's auto-generated per deployment
and must stay constant across rebuilds of the same stack. Drop your three
license files into a local folder (e.g. `~/graphwise-licenses/`), named exactly
`poolparty.key`, `graphdb.license`, `uv-license.key`. Then:

```bash
./scripts/push-config.sh \
  --secrets-file ~/graphwise-secrets.yaml \
  --licenses-dir ~/graphwise-licenses
```

**Rebuild of an existing subdomain:** if you ran `pull-config.sh` before a
`terraform destroy` (see § [Day-2](#10-day-2)), just run `push-config.sh` with
no flags — it auto-discovers the most recent snapshot for the current stack
and restores the saved wildcard TLS cert along with it, saving a Let's Encrypt
weekly issuance slot.

If you want the seeded GraphRAG chat workflows instead of starting n8n empty,
push the kit's workflow seed up now too — the filename has to match the glob
`workflows*.sql` the EC2-side restore script looks for:

```bash
./scripts/stack-scp.sh ../n8n_db_script_v.1.1.0.sql :workflows-baseline-v1.1.0.sql
```

---

## 9. Deploy

On the EC2 (not your laptop):

```bash
cd ~/gsb
./scripts/deploy-stack.sh <sub> <base_domain>
```

This one command chains the full build — cluster bootstrap, license/realm
setup, both Helm installs, and (if you pushed one in step 8) the workflow seed
restore. It takes 15–20 minutes; Graph Modeling (PoolParty) is always the last
pod to go `Running`. Watch it:

```bash
kubectl get pods -A -w        # Ctrl-C once everything is 1/1 Running
```

For what's actually being installed, the full app URL and credential table,
and troubleshooting if a pod won't come up, see
[STACK-BUILDER.md § What you get](STACK-BUILDER.md) and
[STACK-BUILDER.md § App URLs and credentials](STACK-BUILDER.md).

### First login: set the PoolParty superadmin password

Open Graph Modeling at `https://poolparty.<sub>.<base_domain>/PoolParty/` and
log in with the factory credentials `superadmin` / `poolparty`. When prompted
to change the password, set it to **exactly**:

```
corgiDAD#2
```

This isn't optional and there's no safe substitute: the stack's extractor
health-check (`poolparty-extractor-guard.sh`, which runs automatically after
every EC2 stop/start) authenticates as `superadmin` with this exact password
by default, and any workflow wiring you do later that calls the Extractor API
assumes it too. Setting anything else breaks that wiring.

Wherever you need the basic-auth form of this credential (for example, an
`EXTRACTOR_AUTH` header), derive it with base64 — never plain `echo`, since a
trailing newline changes the encoding:

```bash
printf 'superadmin/corgiDAD#2' | base64
# → c3VwZXJhZG1pbi9jb3JnaURBRCMy
```

Note the separator is a slash (`/`), not the colon `curl -u` normally uses.

---

## 10. Day-2

Once the stack is up, day-to-day operation is covered in full in
[STACK-BUILDER.md § Day-2 lifecycle](STACK-BUILDER.md)
(polite stop/start, wipe-and-reinstall, chart upgrades, AMI-based multi-stack
management, logo branding). The laptop-side entry points you'll reach for most:

- **`ec2-power.sh`** — list your stack instances (running and stopped) and
  start or stop one, with a confirmation prompt.
- **`cluster-stop.sh`** (on the EC2, before stopping the instance) /
  auto-resume on boot via `cluster-resume.sh` — see STACK-BUILDER.md for the
  full stop/start sequence.
- **`aws-manage-inbound-ip.sh`** — when your laptop's IP changes, this fixes
  the now-stale admin `/32` on every stack's security group (Terraform stops
  managing that rule after the first apply). Dry-run by default; `--apply` to
  write. Also update `admin_cidr` in `terraform.tfvars` so a future
  destroy/apply doesn't reintroduce the old IP.
- **`check-tags.sh`** — audit (and fix) the org compliance tags across your
  AWS account.

---

## 11. Kit script reference

All 8 scripts live in `laptop-kit/terraform-aws/scripts/` and run from
`laptop-kit/terraform-aws/` on your laptop — not on the EC2.

| Script | What it does |
|---|---|
| `check-prereqs.sh` | Read-only macOS preflight: toolchain, AWS auth, Python/PyYAML. Run before anything else. |
| `manage-stacks.sh` | Adds/lists/removes per-stack SSH alias blocks in `~/.zprofile`; the `GW_KEY_*`/`GW_HOST_*` vars it writes are read automatically by `stack-scp.sh`, `pull-config.sh`, and `push-config.sh`. |
| `stack-scp.sh` | `scp` wrapper that resolves the key/host from `~/.zprofile`; prefix an EC2-side path with `:`. |
| `pull-config.sh` | Snapshots the live EC2's secrets, license files, and wildcard TLS cert into a dated local folder — run before every `terraform destroy` you plan to rebuild from. |
| `push-config.sh` | Restores licenses/secrets (and, on a rebuild, the saved cert) to a freshly provisioned EC2 — see § [Push config](#8-push-config). |
| `ec2-power.sh` | Lists your stack EC2 instances (running and stopped) and starts/stops one you pick, with confirmation. |
| `check-tags.sh` | Audits (and, on confirmation, fixes) the org compliance tags across your whole AWS account. |
| `aws-manage-inbound-ip.sh` | Fixes the admin `/32` ingress rule on stack security groups after your laptop's IP changes; also the only way to temporarily open a stack's HTTPS port to the world for a demo (`--open-public` / `--close-public`) — SSH can never be world-opened through it. Dry-run by default. |

For anything beyond a one-line summary — flags, examples, exit codes — each
script documents itself in its own header comment. For the EC2-side scripts
under repo-root `scripts/`, see
[STACK-BUILDER.md § Appendix: scripts reference](STACK-BUILDER.md).
