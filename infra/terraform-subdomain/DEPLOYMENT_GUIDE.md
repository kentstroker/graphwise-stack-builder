# Kit **INTERNAL USE ONLY**
# Graphwise Stack Builder
This document is for an end-user to be able to deploy and destroy a full stack. The Graphwise Stack Builder (GSB)
is a Terraform-drive, AWS, EC2+KIND (Kubernetes on Docker) automated deployment tool
that stands up an entire Graphwise AI Suite.
---
## Table of Contents

- [Kit layout](#kit-layout)
- [Kit Scripts](#kit-scripts)
  - [`check-prereqs.sh` — Laptop preflight](#check-prereqssh--laptop-preflight)
  - [`manage-stacks.sh` — SSH multi-stack manager](#manage-stackssh--ssh-multi-stack-manager)
  - [`stack-scp.sh` — Authenticated file transfer](#stack-scpsh--authenticated-file-transfer)
  - [`pull-config.sh` — Snapshot EC2 secrets and cert to laptop](#pull-configsh--snapshot-ec2-secrets-and-cert-to-laptop)
  - [`push-config.sh` — Restore secrets and cert to a fresh EC2](#push-configsh--restore-secrets-and-cert-to-a-fresh-ec2)
  - [Typical destroy-and-rebuild flow using the kit scripts](#typical-destroy-and-rebuild-flow-using-the-kit-scripts)
- [Laptop Prerequisites](#laptop-prerequisites-one-time-laptop)
- [ZSH Profile SSH Convenience](#zsh-profile-ssh-convenience)
- [Stack Deployment Steps](#stack-deployment-steps)
  - [Create an EC2 Key Pair](#create-an-ec2-key-pair)
  - [1. Allocate an Elastic IP](#1-allocate-an-elastic-ip-laptopconsole)
  - [2. Add DNS records](#2-add-dns-records-in-the-gw-psecom-route-53-zone-laptop--console)
  - [3. Create the Subdomain Working Folder](#3-create-the-subdomain-working-folder-laptop)
  - [4. Edit `terraform.tfvars`](#4-edit-the-terraformtfvars-file-laptop)
  - [5. Fill in `graphwise-secrets.yaml`](#5-fill-in-the-graphwise-secretsyaml-files-laptop)
  - [6. Fill in `n8n.txt`](#6-fill-in-the-n8ntxt-file-laptop)
  - [7. Provision the EC2 Instance](#7-provision-the-ec2-instance-laptop)
  - [8. Finish the Build Over SSH](#8-finish-the-build-over-ssh-ec2)
  - [9. Verify the Stack](#9-verify-the-stack-ec2)
  - [10. Add Customer Logo (optional)](#10-optional-add-customer-logo-to-console-landing-page-laptopec2)
  - [11. GraphRAG n8n chat engine](#11-graphrag-n8n-chat-engine-ec2)
  - [12. Run `pull-config.sh`](#12-run-pull-stacksh)
  - [12b. Rebuilding the Same Subdomain](#12b-rebuilding-new-stack-using-the-same-subdomain-name)
- [Post Deployment Tasks](#post-deployment-tasks)
  - [Loading Data to Staging](#loading-data-to-staging-laptop)
- [Stack Tear Down](#stack-tear-down-laptop)
- [Troubleshooting](#troubleshooting)
  - [Watch Pod Startup](#watch-pod-startup)
  - [Read the bootstrap log](#read-the-bootstrap-log)
  - [Get Logs From Any Pod](#get-logs-from-any-pod)
  - [Get Kubernetes Events](#get-kubernetes-events)
  - [TLS Certificate Issues](#tls-certificate-issues--forcing-lets-encrypt-to-re-issue)
- [Kubernetes Dashboard and Grafana](#kubernetes-dashboard-and-grafana)

---
## User Deployment Guide
- Version: v.2.0.0
- Author: Kent Stroker
- Date: July 2, 2026
---
Once three (files) are editing with your own credentials and stack specific details, then only a single command 
(terraform apply) is required to build the entire stack. A stack can be completely
delted with a single command (terraform destroy).

> This document ships inside the downloadable **laptop kit**
> (`graphwise-stack-builder-kit-v.2.0.0.tar.gz`) — **get it from Kent**, extract it, and run
> everything from within the extracted folder. This file is only available from Kent as the kit contains
> credentials and licenses keys only approitae for **INTERNAL** use only. If standing up a stack for customer
> access and use, then the proper 30-day licnese should be used and **NOT** internal
> use licenses!

> The heavy lifting (charts, cluster
> scripts) is cloned onto the EC2 automatically by Terraform cloud-init — you
> never copy those by hand.
>
> > **The only AWS resources you provision in the Console are the Elastic IP
> (step 1) and the Route 53 records (step 2)** — and even those can be done from
> the CLI. Everything else is Terraform / CLI / SSH from your laptop. No IAM or
> other console clicking. (You may sign in to the Console with your credentials,
> but you don't create anything else there.)

**Base domain:** `gw-pse.com` (Route 53 hosted zone in the deployment AWS
account). Substitute your own values for `<sub>` (subdomain), `<eip>` (Elastic
IP), `<key.pem>` (your EC2 key).

**Assumes the Graphwise PSE AWS account is already set up** by your account
admin — you do **not** create any AWS accounts, IAM users, or the Route 53
zone. They already exist; you just consume them. 

What you need:
- The CSV file containing your specific AWS access keys (ID + secret). 
- Your IAM account already has all of the necessary permissions to run the full stack including Bedrock and IAM permissions needed by Terraform.
- An **EC2 key pair you create** (step 0) — Terraform attaches it to the
  instance for SSH; keep its `.pem` on your laptop ($HOME/.ssh). Do not lose this file!
- All Graphwsie licenses for internal employee use are included already:
  - Graphwise **maven** user/pass and **n8n Enterprise** key.
  - License files: `poolparty.key`, `graphdb.license`, `uv-license.key`.
  - `n8n.txt` values (AWS key, `EXTRACTOR_AUTH`, `EXTRACTOR_PROJECT_ID`).

You **DO NOT** need to get any Maven or Graphwise licenses, those provided by the stack are appropriate for internal use.

If you're missing any of these, ask your Graphwise PSE AWS account admin — this
checklist does not cover account/IAM provisioning.

There are specific Graphwise AWS tagging requirements for assets. All assets created via Terraform will automatically 
get tags that conform to the requirements.

---

## Kit layout

Files marked `[git-ignored]` are never committed — they are either credentials/licenses you supply,
or Terraform run artifacts generated locally. Everything else is tracked in git and ships in the kit.

```
terraform-subdomain/               (shipped as graphwise-stack-builder-kit-v2.0.0/)
├── DEPLOYMENT_GUIDE.md            ← you are here
│
├── main.tf                        ← EC2 + Elastic IP + security group + IAM
├── variables.tf                   ← all input variables with defaults + descriptions
├── outputs.tf                     ← instance_id, public_ip, DNS names
├── versions.tf                    ← Terraform + provider version pins
├── user-data.sh.tpl               ← cloud-init: preps the host and optionally builds the stack
├── terraform.tfvars.example       ← copy → terraform.tfvars, fill in your values
│
├── terraform.tfvars               [git-ignored] your subdomain, EIP, key pair, admin_cidr
├── graphwise-secrets.yaml         [git-ignored] maven creds, AWS Bedrock keys, n8n license
├── n8n.txt                        [git-ignored] n8n encryption key + API key (must stay constant)
│
├── .terraform/                    [git-ignored] provider plugins — created by `terraform init`
├── .terraform.lock.hcl            [git-ignored] provider version lock file
├── terraform.tfstate              [git-ignored] live state after `terraform apply`
├── terraform.tfstate.backup       [git-ignored] previous state (written on each apply)
│
├── files/
│   ├── n8n-pg-dumpall.sql.tar.gz   ← committed — known-good n8n workflow DB backup
│   ├── n8n-pg-dumpall.sql           [git-ignored] raw uncompressed dump (generated locally)
│   ├── Configuration.js                        [git-ignored] n8n Configuration node — fill in per-deploy paths
│   └── licenses/
│       ├── poolparty.key                       [git-ignored] PoolParty license (you supply)
│       ├── graphdb.license                     [git-ignored] GraphDB EE license (you supply)
│       └── uv-license.key                      [git-ignored] UnifiedViews license (you supply)
│
└── scripts/
    ├── check-prereqs.sh           ← macOS preflight: verifies toolchain + AWS auth
    ├── manage-stacks.sh           ← add/list/remove stack SSH entries in ~/.zprofile
    ├── stack-scp.sh               ← scp wrapper using manage-stacks.sh key/host entries
    ├── pull-config.sh             ← save live secrets + wildcard cert from EC2 to laptop
    └── push-config.sh             ← push secrets + saved wildcard cert to EC2
```

The first step, detailed later in this document, will be to copy the entire terraform-subdomain folder to a new folder (e.g., terraform-customer).
Make edits to three (3) files, and then run a single command to build it out.

---

## Kit Scripts

Five laptop-side scripts live in `scripts/`. Run them from your per-stack Terraform
folder (e.g. `~/Desktop/terraform-kstroker/`), not from the git repo root.

---

### `check-prereqs.sh` — Laptop preflight

Run this **before anything else** on a fresh laptop or after an OS upgrade. It is
read-only — it checks and reports, never changes anything.

**What it checks:**
- macOS version and CPU architecture
- Required CLI tools: Homebrew, AWS CLI, Terraform, SSH, `dig`, `rsync`
- AWS CLI authentication (`aws sts get-caller-identity`)
- Python 3 + PyYAML
- IDE presence (PyCharm, IntelliJ) — informational

```bash
cd ~/Desktop/terraform-kstroker
./scripts/check-prereqs.sh
```

All checks print ✓ (green), ! (warning), or ✗ (error). Fix every ✗ before proceeding.

---

### `manage-stacks.sh` — SSH multi-stack manager

Writes labelled blocks into `~/.zprofile` so you can SSH to any managed stack with
a short alias. Each block exports `GW_KEY_<name>`, `GW_HOST_<name>`, and an alias
whose name you choose at add time (default `ssh<name>`). These variables are also
read by `stack-scp.sh` automatically.

```bash
./scripts/manage-stacks.sh            # interactive menu
./scripts/manage-stacks.sh list       # print all stacks and exit
./scripts/manage-stacks.sh add        # add a new stack (prompts)
./scripts/manage-stacks.sh remove     # remove a stack (picker)
```

**Adding a stack (prompts you for each value):**
```bash
./scripts/manage-stacks.sh add
# Stack name:     kstroker
# Key file path:  ~/.ssh/kstroker-stack-key.pem
# Hostname:       kstroker.gw-pse.com
# Alias name:     sshkstroker   (press Enter for default)
```

After adding, open a new terminal or run `source ~/.zprofile`, then:
```bash
sshkstroker    # expands to: ssh -i ~/.ssh/kstroker-stack-key.pem ec2-user@kstroker.gw-pse.com
```

**Listing all configured stacks:**
```bash
./scripts/manage-stacks.sh list
#   NAME         ALIAS        HOST                     KEY
#   kstroker     sshkstroker  kstroker.gw-pse.com      ~/.ssh/kstroker-stack-key.pem
#   acme         sshacme      acme.gw-pse.com           ~/.ssh/acme-stack-key.pem
```

---

### `stack-scp.sh` — Authenticated file transfer

`scp` wrapper that reads the key and host from your `~/.zprofile` blocks. Prefix any
EC2-side path with `:` to mark it as remote.

```bash
./scripts/stack-scp.sh [--stack <name>] [-r] <source> <dest>
```

With no `--stack`, an interactive picker lets you choose. With `--stack <name>`, it skips
the picker.

**Examples:**
```bash
# Push a customer logo to the EC2
./scripts/stack-scp.sh logo.png :~/logo.png

# Pull a file from the EC2 to the current directory
./scripts/stack-scp.sh :~/wildcard-tls.yaml ./

# Recursive push of a local data folder
./scripts/stack-scp.sh -r ./data :~/staging-data/

# Recursive pull from a named stack (no picker)
./scripts/stack-scp.sh --stack kstroker -r :~/gsb/files/ ./local-backup/
```

---

### `pull-config.sh` — Snapshot EC2 secrets and cert to laptop

SSH to the EC2 and pull everything needed to survive a `terraform destroy`. Run this
**before every destroy.**

**What gets pulled:**
- `graphwise-secrets.yaml` — rebuilt from the live Kubernetes Secrets the pods are consuming
- `licenses/poolparty.key`, `graphdb.license`, `uv-license.key`
- `licenses/wildcard-tls.yaml` — the live Let's Encrypt wildcard cert, ready to restore

Everything lands in a timestamped folder in the current directory:
```
graphwise-config-kstroker.gw-pse.com-20260702T143012Z/
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
cd ~/Desktop/terraform-kstroker
./scripts/pull-config.sh
```

The script picks up `GW_KEY_*` and `GW_HOST_*` from `~/.zprofile` automatically if
`manage-stacks.sh` was used. Otherwise pass them inline:
```bash
GRAPHWISE_KEY=~/.ssh/kstroker-stack-key.pem \
GRAPHWISE_HOST=kstroker.gw-pse.com \
./scripts/pull-config.sh
```

The saved wildcard cert means the next rebuild skips the DNS-01 round trip and avoids
consuming one of your 5-per-week Let's Encrypt rate-limit slots.

---

### `push-config.sh` — Restore secrets and cert to a fresh EC2

Sends the snapshot created by `pull-config.sh` back to a newly provisioned EC2.
Run this **after `terraform apply` but before `cluster-bootstrap.sh`** on the EC2.

**What gets pushed:**

| Snapshot file | EC2 destination |
|---|---|
| `graphwise-secrets.yaml` | `~/graphwise-secrets.yaml` |
| `licenses/poolparty.key` | `~/gsb/files/licenses/` |
| `licenses/graphdb.license` | `~/gsb/files/licenses/` |
| `licenses/uv-license.key` | `~/gsb/files/licenses/` |
| `licenses/wildcard-tls.yaml` | `~/wildcard-tls-saved.yaml` |

```bash
cd ~/Desktop/terraform-kstroker
./scripts/push-config.sh              # auto-discovers most recent snapshot
```

To target a specific snapshot:
```bash
./scripts/push-config.sh --snapshot ./graphwise-config-kstroker.gw-pse.com-20260702T143012Z
```

Useful flags:
```bash
./scripts/push-config.sh --list                        # show available snapshots
./scripts/push-config.sh --skip-cert                   # skip wildcard cert (force fresh LE issuance)
./scripts/push-config.sh --skip-secrets                # licenses + cert only
./scripts/push-config.sh --keep-local-encryption-key  # don't splice the EC2's fresh n8n key
```

The n8n encryption key is handled automatically: `push-config.sh` reads the fresh key
Terraform wrote to the new EC2 and splices it in before sending the secrets file. The old
key from the previous stack is useless on the new database.

---

### Typical destroy-and-rebuild flow using the kit scripts

```bash
# 1. Before destroying — snapshot everything
cd ~/Desktop/terraform-kstroker
./scripts/pull-config.sh

# 2. Destroy
terraform destroy

# 3. Rebuild
terraform apply

# 4. Restore before bootstrap
./scripts/push-config.sh

# 5. SSH to EC2 and continue
sshkstroker
# → run cluster-bootstrap.sh, then reset-helm.sh
```

---

## Laptop Prerequisites  *(one-time, laptop)*

**Your AWS PSE user account has already been created for you.** You are provided with two
**CSV files** with your AWS credentials (Access Key ID + Secret Access Key). Use
them to sign in to the AWS Console if you like, and to set up your AWS CLI
authentication below. 

You will also be provided with the laptop kit (`graphwise-stack-uilder-kit-v.2.0.0.tar.gz`) — extract it and work from that folder.

Install the prereq tools, then configure the AWS CLI with the
access key from that CSV. (Linux/Windows: install the same three tools with your
package manager — `awscli`, `terraform`, and an SSH client.)

macOS — install [Homebrew](https://brew.sh) if you don't have it, use this method:

```bash
# install Homebrew (skip if `brew --version` already works)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install needed tools
brew install awscli terraform        # ssh + dig ship with macOS
```
It is recommended that you work the stack via some type of IDE (PyCharm, VSCode) as this provides an easy way to run code, notebooks and version control coding projects.

Verify the toolchain:

```bash
aws --version && terraform version && ssh -V && dig -v
```

Configure the AWS CLI with the CSV file credentials provided to you from the administrator. Either run the
interactive prompt:

```bash
aws configure            # paste Access Key ID, Secret, region us-west-2, output json
```

…or write the two `~/.aws` files directly (same result — handy when scripting or
managing several profiles):

```bash
mkdir -p ~/.aws && chmod 700 ~/.aws

cat > ~/.aws/credentials <<'EOF'
[default]
aws_access_key_id     = AKIA...your-terraform-demo-key...
aws_secret_access_key = ...your-terraform-demo-secret...
EOF
chmod 600 ~/.aws/credentials

cat > ~/.aws/config <<'EOF'
[default]
region = us-west-2
output = json
EOF
chmod 600 ~/.aws/config
```

Verify it resolves to the right user:

```bash
aws sts get-caller-identity           
```

This concludes the steps necessary for laptop  setup. To furtyher confirm and validate your laptop is
ready to use this kit, run the following command:

```bash
./scripts/check-prereqs.sh
```
The detailed out should come back clean, if not, remediate until it does.

## ZSH Profile SSH Convenience
> HINT: To make accessing multiple stacks easier, create a number of exported variables and aliases in the 
> $HOME/.zprofile . This will amke is really easy to run and access multiple
> stacks using SSH and SCP.

Here is an example of the authors .zprofile settings:
```bash
./scripts/manage-stack.sh
```
Be sure to run `source ~/.zprofile` after making any modifications to the `.zprofile`
file, or restart the terminal session.
---

---

## Stack Deployment Steps
This section details the steps to build out a stack.

> ### AWS Region - Current Restriction
> For various AWS-oriented issues, we need to stick to us-west-2 (Oregon) for now. Future versions will address being able 
to use multiple regions, but for now, we need to stick to us-west-2

### Create an EC2 Key Pair
Create your own key pair and save the private `.pem` on your laptop — Terraform
attaches the public key to the instance, and you SSH in with the `.pem`.:

```bash
aws ec2 create-key-pair --region us-west-2 --key-name {lastname}-stack-key \
  --query 'KeyMaterial' --output text > ~/.ssh/{lastname}-stack-key.pem
chmod 400 ~/.ssh/{lastname}-stack-key.pem
```

Use this **naming convention** (`{lastname}-stack-key`) for `key_pair_name` in `terraform.tfvars`
(step 3), and the `.pem` path (`~/.ssh/{lastname}-stack-key.pem`) as `<key.pem>`
everywhere below.

This is the only key pair you will need, it is used for all stack builds. However, you can easily create a key pair 
for each stack and assign as needed by changing the value in the terraform.tfvars file. For nbow, just use the
one key pair.

## 1. Allocate an Elastic IP  *(laptop/console)*
Since each stack built is resolvable using DNS, and has TLS security (using Let's Encrypt), each stack
needs to have a static IP, this is called an Elastic IP (EIP) in AWS lingo.

```bash
aws ec2 allocate-address --domain vpc --region us-west-2
# Save BOTH "AllocationId" (eipalloc-…) and "PublicIp" (<eip>) from the output.
```
Make note of noth the static IP allocated, and the allocation ID (e.g. eipalloc-0f22...) as you will
need them in later steps.

The EIP is pre-allocated so it survives `terraform destroy`/`apply` cycles and
your DNS never needs re-pointing. You need an EIP for each stack you plan to maintain. 
If you later permanently destroy the stack, be sure to delete the EIP to stop charges for the EIP, 
and remove the A records from DNS.

## 2. Add DNS records in the `gw-pse.com` Route 53 zone  *(laptop / console)*

> NOTE: We use a shared Route 53 zone, gw-pse.com, and it has a hosted zone id of `Z03476331NSJ3X9EZAGNE`. This is the
> zone idea to use in the terraform.tfvars file - **DO NOT CHANGE THIS!!!**

Using the AWS Console, add two A records, **both** pointing at `<eip>`:

| Name | Type | Value |
|---|---|---|
| `<sub>.gw-pse.com` | A | `<eip>` |
| `*.<sub>.gw-pse.com` | A | `<eip>` |

Better yet, add them from the CLI (`UPSERT` = create-or-update, so it's safe to re-run):

```bash
SUB=<sub>                         # your subdomain
EIP=<eip>                         # PublicIp from step 1
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

Verify (after a few seconds for propagation):

```bash
dig +short <sub>.gw-pse.com poolparty.<sub>.gw-pse.com   # both must print <eip>
```

DNS must be live **before** the build step (step 7) — cert-manager needs it for
the wildcard certificate.

## 3. Create the Subdomain Working Folder  *(laptop)*

Copy the template out of the kit and name it for this project (e.g.
`terraform-kent`). This folder becomes the home for
everything about this subdomain.

```bash
cp -r infra/terraform-subdomain ~/Desktop/terraform-<sub>
cd ~/Desktop/terraform-<sub>
```

There are several files that must be created and edited prior to running the
terraform build command. Once of them is terraform.tfvars. This is the file where you define the subdomain,
associate with EIP and other stack specific values.

Use an editor of your choice (i.e., PyCharm, VSCode, vi, BBedit, etc.).


## 4. Edit the `terraform.tfvars` File (*(laptop)*)
Set the required fields:

```hcl
region                     = "us-west-2"
base_domain                = "gw-pse.com"
subdomain                  = "<sub>"
route53_zone_id            = "Z..."            # zone ID for gw-pse.com
le_email                   = "you@graphwise.ai"
key_pair_name              = "graphwise-<sub>" # the key pair you created in step 0 (name only, no .pem)
admin_cidr                 = "<your-ip>/32"    # curl -4 icanhazip.com
availability_zone          = "us-west-2a"
existing_eip_allocation_id = "eipalloc-…"      # from step 1
```

## 5. Fill in the `graphwise-secrets.yaml` files  *(laptop)*
The graphwise-secrets.yaml file is partially filled out for you. 
The kit TAR file contains much of the values already set for you. Open with your
favorite editor and confirm/alter as needed.

> Leave `n8nEncryption.key` **AS IS* in `graphwise-secrets.yaml`.

## 6. Fill in the `n8n.txt file` *(laptop)*
The `n8n.txt` is needed during a later step, only change the

```bash
AWS_ACCESS_KEY_ID={your AWS AWS_ACCESS_KEY_ID for CSV provided}
AWS_SECRET_ACCESS_KEY={your AWS_SECRET_ACCESS_KEY }
EXTRACTOR_AUTH=Basic c3VwZXJhZG1pbjpjb3JnaURBRCMy
```

>NOTE: *DO NOT* change the EXTRACTOR_AUTH or you will break the embedded superadmin user password.

## 7. Provision the EC2 Instance  *(laptop)*
You *MUST* be in the subdomain folder to run this. Each subdomain is indepenednt of anyothers, so running 
multiple stacks is supported.

```bash
terraform init
terraform plan                 
terraform apply                
```

Once the terraform apply commands exits, Login in via SSH and monitor
for cloud-init to finish (KIND cluster comes up after apply returns):

```bash
ssh -i <key.pem> ec2-user@<sub>.gw-pse.com 
kubectl get nodes -A
# or use the alias you set using manage-stack.sh
# Once ssh'ed into the EC2
tail -f /var/log/bootstrap.sh
```
Monitor until bootstrap finishes, Ctrl-C to exit.

> NOTICE: If this is a re-deploy of a previously existing 
> subdomain AND you did a pull, now is the time to do a push.

## 8. Finish the Build Over SSH  *(EC2)*

### Method One - Single Script (do this after you gain experience)
```bash
ssh -i <key.pem> ec2-user@<sub>.gw-pse.com
cd ~/gsb
./scripts/deploy-stack.sh <sub> gw-pse.com

# Or better yet, use manage-stack.sh then call an alias
# e.g., $ ssh-kstroker
```

### Method Two - Multiple Scripts (Recommended)
Run the following scripts in this order:

```bash
# Before running anything in here, the terraform apply - cloud-init step needs to be finished
# Check by running kubectl get pods -A and ensure all pods are running
cd gsb
./scripts/cluster-bootstrap.sh
# Wait until `kubectl get pods -A` shows all pods are up before running the next command
./scripts/validate-bootstrap.sh
./scripts/extract-poolparty-realm.sh
./scripts/preflight-reset-heml.sh
./scripts/reset-helm.sh --yes {sub} gw-pse.com
# Wait until kubectl get pods -A shows all pods running with 1/1 status
./scripts/restore-n8n-dumpall.sh
./scripts/validate-stack.sh
```
Example of the kubectl command to check status:
```bash
# One-shot of status
kubectl get pods -A

# Live stream of status
kubectl get pods -A -w 
```
When all of the pods show running, then the stack is built.

> NOTE: Historically, it takes 15 to 20 minutes to reach this point, the Graph Modeling (PoolParty) tool is always 
> the last to complete

## 9. Verify the Stack *(EC2)*

```bash
export APEX=<sub>.gw-pse.com
for h in $APEX poolparty.$APEX auth.$APEX graphdb.$APEX graphrag.$APEX; do
  printf '%-45s ' "$h"; curl -s -o /dev/null -w 'http=%{http_code}\n' "https://$h/" --max-time 10
done
```

Then browse `https://<sub>.gw-pse.com/` (Console). Credentials and the full URL
list are in `CONSOLE-GUIDE.md` (included in this kit).

## 10. (Optional) Add Customer Logo to Console Landing Page *(Laptop+EC2)*
To personalize for a customer POC, there is a script to run that sets the logo image:

```bash
# Run from EC2
./scripts/set-logo.sh
```
Before running this script, the PNG (only supported format) must be uploaded
to the EC2 instance using scp, as follows:
```bash
# Run from laptop
scp -i $GRAPHWISE_KEY logo.png $GRAPHWISE_USER@$GRAPHWISE_HOST:
```
The logo will now appear in the top banner on the right-side. Since the top banner is blue, a logo that 
has a transparent background will display the best.

## 11. n8n Workflows Tool Setup *(EC2)*

Configuring n8n requires a few more steps after the stack is built. The script `./script/restore-n8n-dumpall.ch` 
drops the initial n8n database and populates it with the seed from the SQL
dump file.

It is now necessary to edit the JavaScript code in the Configuration node and
also setup the various credentials n8n needs to access various parts of the stack.

1. Using a browse, open the landing page at subdomain.gw-pse.com.
2. Open the n8n Workflow pane.
3. Login using your Graphwise email address and set a password

3. Click on the Configuration workflow
4. Replace all of the Javascript code with the contents of Configuration.js
5. Look for the following lines in the newly pasted Javascript:
   *  

graphDBMcpUrl: "https://graphdb-projects.va-benefits.gw-pse.com/mcp",
graphDBMcpRepository: "va-benefits"
keycloakUrl: "https://auth.va-benefits.gw-pse.com"
poolPartyServerUrl: "https://poolparty.va-benefits.gw-pse.com"
poolPartyProjectId: "030e1eeb-ee6c-49e0-9ba8-14481c2da848"
"vectorIndex": "va-doc-chunks"

## 12. Run `pull-stack.sh`

Since Let's Encrypt places limits on the numebr of times a subdomain.gw-pse.com can be generated in one week (5 times) before reverting 
to staging mode - and breaking nearly everything - it is **CRITICAL** to run the laptop `./scripts/pull-stack.sh`.

```bash
cd to {current stack folder]
./scripts/pull-stack.sh}
```
This resulting in a timestamped folder being generated with all of the credentials, secrets,
licenses and LE-production certificates downloaded to the laptop.

### 12b. Rebuilding New Stack USing the Same Subdomain Name

If you need to destroy the stack with the intention to rebuild it again (sort of a nuclear reset), you can save time and NOT trigger Let's 
Encryt by:

1. Running a new terraform apply
2. This run MUST be manual, so edit the user-data.sh.tpl if needed.
3. After the successful `terraform apply` and **BEFORE* running the EC2 `$HOME/gsb/scripts/cluster-bootstrap.sh`
run the laptop `./scripts/push-stack.sh`
4. Aftyer the push, resume the stack build on the EC2 instance.

---

---
## Post Deployment Tasks

### Automatic Shutdown Enabled
To save costs, each stack has an automatic shutdown Cloudwatch Alarm deployed.
The stack will shutdown once CPU Utilization drops below 3% for 1-hour.

Restart the stack EC2 instance using either tyhe console or a command line command. 
The stack has an auto resume script called during the booting process and it takes ~5 minutes to
bring all services back online.

### Loading Data to Staging *(laptop)*
The stack is built in such a way that the EC2 $HOME/staging-data folder is available to pods within the KIND deployment stack.
Use scp to upload files needed for ingestion to the stack.

```bash
# Run from laptop
scp -r -i $GRAPHWISE_KEY {source_folder} $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data
```

### Stack Tear Down  *(laptop)*

`terraform destroy` deletes the EC2 and its EBS volume — **all stack data is
lost** (PoolParty projects, GraphDB repos, Keycloak users, n8n workflows,
ingested docs). The EIP and DNS survive (pre-allocated), so a later `apply`
reuses the same address.

> IMPORTANT: **Before destroying**, snapshot the deployment so you can rebuild without
burning a weekly Let's Encrypt allocation:

There is a weekly limitation on the numer of production Let's Encrypt certificates that may be generated. 
In order to not exhaust the allocation it is *SUPER IMPORTANT* that if you are destroying the stack and plan to
create an exact new version, then you *MUST* run the following command:

```bash
cd <path-to-extracted-kit>
./scripts/pull-config.sh          # saves secrets + the live wildcard cert to ~/Downloads
```

Then destroy from your subdomain's Terraform folder:

```bash
cd <path-to-extracted-kit>
terraform destroy
```

On the next rebuild, use `push-config.sh` (not `push-initial.sh`) to restore the
saved cert along with your secrets.

```bash
cd <path-to-extracted-kit>
./scripts/push-config.sh          # restores secrets + the live wildcard cert
```
---

---
## Troubleshooting

### Watch Pod Startup

One-shot snapshot of every pod across every namespace:

```bash
kubectl get pods -A
```

Live watch — refreshes as pods change state (Ctrl-C to exit):

```bash
kubectl get pods -A -w
```

Narrow to a single namespace when you know where to look:

```bash
kubectl get pods -n graphwise
kubectl get pods -n graphrag
kubectl get pods -n keycloak
kubectl get pods -n cert-manager
```

### Read the bootstrap log

The entire cloud-init + build output streams to `/var/log/bootstrap.log`.
Follow it live in a second SSH session while the build runs:

```bash
ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST
sudo tail -f /var/log/bootstrap.log
```

Useful to diagnose a stalled or failed first build before the stack is up.

### Get Logs From Any Pod

```bash
# Logs for a specific pod
kubectl logs -n <namespace> <pod-name>

# Stream live (equivalent to tail -f)
kubectl logs -n <namespace> <pod-name> -f

# Last 100 lines only
kubectl logs -n <namespace> <pod-name> --tail=100

# Multi-container pod — specify the container
kubectl logs -n <namespace> <pod-name> -c <container-name>

# Previous container instance (useful after a crash-loop)
kubectl logs -n <namespace> <pod-name> --previous
```

To find the exact pod name when you only know the app:

```bash
kubectl get pods -n graphwise | grep poolparty
# then copy the name from the output
```

### Get Kubernetes Events
TYhis is often more useful than logs for startup failures.

```bash
kubectl get events -n <namespace> --sort-by='.lastTimes
tamp'
```

Events explain why a pod is `Pending`, `CrashLoopBackOff`, or stuck in `Init`.

## TLS Certificate Issues — Forcing Let's Encrypt to Re-issue

Let's Encrypt rate-limits duplicate certificate requests to **5 per week per
registered domain**. If you hit the limit (or ended up with a staging cert
during testing), the fix is to delete the wildcard TLS Secret — cert-manager
detects it is gone and immediately issues a fresh request to the production
ACME endpoint.

> THINK TWICE before reissuing.

**Force re-issuance:**

```bash
kubectl delete secret wildcard-tls -n cert-manager
```

Kubernetes Reflector auto-removes the mirrored copies in `graphwise`,
`graphdb`, `graphrag`, `keycloak`, and `monitoring`, then repopulates them
once the new cert arrives (~2–3 minutes via DNS-01/Route 53).

**Monitor progress:**

```bash
# Watch the Certificate resource flip to Ready=True
kubectl get certificate wildcard-tls -n cert-manager -w

# If it stalls, inspect the ACME Order and Challenge objects
kubectl get order,challenge -n cert-manager
kubectl describe order -n cert-manager | tail -30
```

**If the ClusterIssuer itself was pointed at the LE staging server**, reset it
first, then delete the Secret:

```bash
kubectl patch clusterissuer letsencrypt-prod \
  --type=merge \
  -p '{"spec":{"acme":{"server":"https://acme-v02.api.letsencrypt.org/directory"}}}'

kubectl delete secret wildcard-tls -n cert-manager
```

> **Why staging certs break the stack:** PoolParty's JVM client validates the
> full TLS chain when it talks to Keycloak at startup. The Let's Encrypt staging
> chain is not trusted by the JVM's default trust store, so the OIDC handshake
> fails and PoolParty never becomes Ready. Always use `letsencrypt-prod`.


Useful commands from troubleshooting Lets Encrypt certificates.
```bash
  kubectl describe certificate wildcard-tls -n cert-manager | tail -30                                                                                                                                                      
  kubectl get challenges -n cert-manager 2>/dev/null                                                                                                                                                                        
  kubectl get orders -n cert-manager 2>/dev/null                                                                                                                                                                            
  kubectl logs -n cert-manager deploy/cert-manager --tail=40 2>&1 | grep -iE 'error|denied|challenge|dns|present'
```

---

---
## Kubernetes Dashboard and Grafana
The stack includes both a Kubernetes Dashboard and a Prometheus+Grafana dashboard.

### Kubernetes Dashboard

In order to use the Kubernetes Dashboard you need perform a pull, and in that pull is a file called `dashboard-kubeconfig.yaml`.
When you launch the dashboard from the landing page, choose the file method to
authenticate and use this file as that file. 

Each stack will have it's own authentication key.

### Grafana
The Granafa at this time has no GrapDB or other Graphwise-specific recipes. The underlying Prometheus however is 
pulling a ton of metrics in from the KIND stack.

A future enhancement to this stack will be pre-seeded dashboards
from Graphwise producs, with insights to the GrapDB being the most pressing.

To access, just lauinch the pane and use the user and password shown on the pane.