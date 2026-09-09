# Graphwise Stack — Azure module

Provisions the Graphwise Stack on a **single Azure Linux VM** running KIND,
as an alternative to the AWS/EC2 path in [`../terraform-aws/`](../terraform-aws/).

> **Status: unvalidated.** Every file here has been formatted, `terraform
> validate`d, and the cloud-init template has been rendered and shell-syntax
> checked — but **nothing has been applied to a live Azure subscription yet.**
> Three items are flagged in-place as unverified (marketplace image triple,
> Docker CE containerd version vs. the KIND pin, and the `az` command shapes
> in the helper scripts). Treat the first deploy as a bring-up, not a repeat.
>
> The **three changes outside this folder** that the Azure path requires are
> now applied and unit-tested against both cloud paths — see
> [Required shared-script changes](#required-shared-script-changes).

---

## The short version

**The stack is cloud-agnostic.** All 13 Helm charts, KIND, Docker, every
cluster operator, every app image, both release orderings, and all the day-2
scripts (`cluster-bootstrap.sh`, `reset-helm.sh`, `cluster-stop/start/resume.sh`,
`check-image-versions.sh`, …) carry over **untouched**. What is cloud-specific
is one Terraform module and one cloud-init script — which is what this folder is.

Two decisions collapse most of the porting work:

1. **DNS stays in Route 53.** cert-manager keeps its `route53` DNS-01 solver;
   only the *authentication* changes, from an EC2 instance role to a static,
   zone-scoped IAM key pair.
2. **The admin account is still called `ec2-user`.** Not a leftover — a
   deliberate choice that makes twelve files zero-edit.

Both are explained below.

---

## Isolation

This folder is **self-contained**. It shares no Terraform state, no provider
config, and no variables with the AWS module. Nothing here can affect an AWS
deployment, and vice versa. Even the ignore rules are folder-local
(`.gitignore` here, rather than an edit to the repo root) so the Azure work
can be lifted out and handed to a teammate on its own — the same way
`infra/terraform-aws/` is distributed.

Three files outside this folder carry small additive, capability-gated edits —
`scripts/cluster-bootstrap.sh`, `scripts/preflight-reset-helm.sh`, and
`scripts/render-values.sh`. Each was verified to leave the AWS path
semantically unchanged. See
[Required shared-script changes](#required-shared-script-changes).

---

## Why Route 53 stays

The AWS module wires cert-manager to Route 53 through an instance role:

```
cert-manager pod → AWS SDK → IMDSv2 → EC2 instance role → Route 53
```

An Azure VM has no way to assume an AWS IAM role, so that chain has to be
replaced. There were two options, and moving DNS to Azure DNS is the more
expensive one:

| | Keep Route 53, static key | Move to Azure DNS |
|---|---|---|
| cert-manager change | swap solver auth (~10 lines) | new `azureDNS` solver block |
| Identity plumbing | one scoped IAM user | managed identity + role assignment on the zone |
| New failure mode | none | Azure IMDS must reach a pod **two network namespaces deep** inside a KIND node container |
| DNS migration | none | move the zone, re-delegate nameservers |
| Couples to | nothing | "run on Azure" now *requires* "move the zone" |

The IMDS-through-KIND problem is not hypothetical — the AWS module carries
`http_put_response_hop_limit = 3` precisely because the default of 1 (and even
the usual K8s value of 2) made IMDS unreachable from a cert-manager pod, and
that failure presents as *"no EC2 IMDS role found"* with a wildcard cert that
never issues. Reproducing that debugging session against Azure IMDS, for no
functional gain, is a bad trade.

**The obvious objection, answered honestly:** the AWS module's comments sell
the instance-role approach as *"no AWS access key Secret needs to live in the
cluster."* That property is **already gone**. `poolparty-aws-credentials`
(graphwise ns) and `graphrag-components-aws-credentials` (graphrag ns) are
static `AKIA…` keys today, for Bedrock. Adding a third static key — scoped
to `ChangeResourceRecordSets` on one hosted zone — is not a new class of
exposure.

Scope the IAM user exactly as the AWS module's role policy does:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "route53:GetChange",
      "Resource": "arn:aws:route53:::change/*" },
    { "Effect": "Allow",
      "Action": ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"],
      "Resource": "arn:aws:route53:::hostedzone/<YOUR_ZONE_ID>" }
  ]
}
```

Put the key in `route53-credentials.env` next to this README (gitignored):

```
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-west-2
```

Terraform inlines it into cloud-init, which writes it to
`~/.graphwise-route53.env` (mode 600) on the VM. `/etc/profile.d/graphwise.sh`
sources it, so `cluster-bootstrap.sh` finds `AWS_ACCESS_KEY_ID` in its
environment — and that presence is the signal it uses to pick the static-key
ClusterIssuer form.

> This IAM user is **separate from** the `graphrag-bedrock` user whose keys
> live in `~/graphwise-secrets.yaml`. Different policies, different blast
> radius. Do not merge them.

**Bedrock needs no change at all.** `poolparty.llm.api: bedrock` and GraphRAG's
`EMBEDDING_PROVIDER: aws` authenticate with static keys in a Secret, and an
AWS access key does not care which cloud the caller sits in. The stack on
Azure calls Bedrock over the internet, unchanged — zero code edits. The costs
are cross-cloud egress and a little latency, plus the standing requirement
that operators hold an AWS account. That is a product constraint, not a
porting one. (Switching to Azure OpenAI would mean modifying the vendored
`charts/vendor/graphrag/` charts, which hardcode `aws` with no alternative
exposed — a different and much larger project.)

---

## Why the admin user is still `ec2-user`

`ec2-user` appears in twelve files in this repo. The one that decides the
question is `infra/kind/kind-config.yaml`:

```yaml
extraMounts:
  - hostPath: /home/ec2-user/staging-data
    containerPath: /staging-data
```

That file is **static YAML with no templating path whatsoever** — it is passed
directly to `kind create cluster --config`. Parameterizing the username means
inventing substitution machinery for a file that has none, and then chasing the
same change through `charts/graphwise-stack/templates/staging-data.yaml`, the
`graphwise-cluster-resume.service` unit, and the laptop ssh/scp helpers.

Reusing the literal name makes all twelve files zero-edit and keeps the Azure
and AWS paths byte-identical from the KIND layer up. `ec2-user` is not on
Azure's reserved-username list; `variables.tf` validates against that list
anyway, in case someone overrides it.

It looks odd in the Azure Portal. That is the entire cost.

---

## Why x86_64, not ARM64

`Standard_E8s_v5` (8 vCPU / 64 GiB, x86_64) is the default, mapping to the AWS
module's `r6g.2xlarge`. `Standard_E8ps_v5` is the ARM64 equivalent if you want
it, but x86 is the better choice here for a reason beyond regional availability:

The bundled `refine/ontorefine-1.2.1/` dist, `infra/refine-image/Dockerfile`,
and `scripts/build-refine-image.sh` all exist for exactly one reason —
`ontotext/refine` is **amd64-only** on Docker Hub, and Graviton can't run it.
On x86 that whole workaround is unnecessary.

`scripts/render-values.sh` now handles this automatically: on `x86_64` it emits
`repository: ontotext/refine`, and on `aarch64`/`arm64` it falls through to the
unchanged local-build branch. No manual override, and nothing to remember. The
bundled dist stays in the repo — every existing arm64 stack still needs it.

Every other image in the stack was verified multi-arch during the 2.2.7/2.2.8
version sweeps, so x86 is a strict superset. Zero image risk, one workaround
retired.

---

## Prerequisites

```bash
./scripts/check-prereqs-azure.sh
```

That checks most of it. Three things it can't check:

1. **Marketplace terms.** Rocky is a plan image; without a one-time
   per-subscription acceptance every apply fails with *"Legal terms have not
   been accepted for this item on this subscription."*
   ```bash
   az vm image terms accept --publisher resf --offer rockylinux-x86_64 --plan 9-base
   ```
   This is a documented CLI step rather than an `azurerm_marketplace_agreement`
   resource on purpose: that resource is subscription-scoped and conflicts if
   the terms were already accepted by another deployment.

2. **VM size availability** is regional and E-series coverage varies:
   ```bash
   az vm list-skus --location <location> --size Standard_E8 --output table
   ```

3. **The public IP** should be created **once, in a resource group this module
   does not manage.** This matters more than the EIP does on AWS: `terraform
   destroy` deletes the entire resource group, so a Terraform-managed IP is
   *guaranteed* lost on every rebuild, taking your Route 53 A records with it.
   ```bash
   az group create --name graphwise-shared-rg --location westus2
   az network public-ip create --name graphwise-<sub>-pip \
       --resource-group graphwise-shared-rg --location westus2 \
       --sku Standard --allocation-method Static
   ```

---

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in every CHANGEME
$EDITOR route53-credentials.env                # three lines, see above
./scripts/check-prereqs-azure.sh

terraform init
terraform plan
terraform apply

terraform output route53_dns_records           # run the command it prints
terraform output image_pin_command             # run it, paste result into tfvars
```

Then wait ~10–15 min for cloud-init, and:

```bash
eval "$(terraform output -raw graphwise_env_exports)"
ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST 'sudo tail -f /var/log/bootstrap.log'
# once you see "Bootstrap complete":
ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST
cd ~/gsb && ./scripts/deploy-stack.sh <subdomain> <base_domain>
```

From `deploy-stack.sh` onward the flow is **identical to the AWS path** — same
scripts, same charts, same URLs, same credentials.

---

## Parking the stack — the deallocate trap

**This is the single most expensive difference between the two paths.**

| | AWS | Azure |
|---|---|---|
| `aws ec2 stop-instances` | meter stops ✅ | — |
| `az vm stop` | — | **still billing** ❌ |
| `sudo shutdown -h now` | meter stops ✅ | **still billing** ❌ |
| `az vm deallocate` | — | meter stops ✅ |

An Azure VM that is merely *Stopped* keeps billing for compute. Only
*Stopped (deallocated)* releases the hardware. In the Portal both read
"Stopped" at a glance, so a teammate carrying over the AWS habit pays full
price for an idle 8-vCPU / 64 GiB box indefinitely with nothing shouting
about it.

Use the wrapper, which only ever deallocates and prints the raw power state:

```bash
./scripts/azure-vm-power.sh status
./scripts/azure-vm-power.sh deallocate
./scripts/azure-vm-power.sh start
```

Managed disks and the Static/Standard public IP both survive deallocation, so
the stack returns on the same address with all PVCs intact, and
`graphwise-cluster-resume.service` restores the workloads automatically.

---

## Auto-shutdown — a behaviour change, not a port

The AWS module uses `arn:aws:automate:<region>:ec2:stop`, a free native
CloudWatch alarm action that fires after **1 hour of idle CPU**. Azure Monitor
has no equivalent VM-stop action.

This module ships `azurerm_dev_test_global_vm_shutdown_schedule` instead —
one resource, no runbook, and it correctly *deallocates*. But it is
**time-based, not idle-based**: it will shut the VM down at the configured hour
whether or not a demo is in progress.

Mitigations, in order:

- Set `auto_shutdown_notification_email`. The 30-minute warning mail carries a
  **postpone** link, which is the only in-band escape.
- Set `auto_shutdown_enabled = false` on demo days.
- For genuine idle-based parity, build: Azure Monitor metric alert on
  Percentage CPU → action group → Automation runbook (or Function) calling
  `Stop-AzVM -Force`. Roughly four extra resources plus a runbook to maintain.
  Deliberately not shipped — it is a real chunk of infrastructure for a demo
  cost guard.

---

## Known risks

**1. Docker CE's containerd version vs. the KIND pin.** *Highest risk in the port.*

Rocky/RHEL have **no `docker` package** — the distro ships podman — so
cloud-init installs Docker CE from `download.docker.com`. On AL2023 the
bundled `docker` package pins host containerd at 2.2.x, and *that* is what
makes the `KIND v0.30.0` pin safe (a KIND node whose containerd is newer than
the host's breaks `kind load`; KIND 0.32.0's node ships containerd 2.3.1 with
config v4, which a 2.2.x host cannot read). Docker CE's `containerd.io`
package version is an **independent moving target**, so that relationship is
no longer guaranteed by the distro.

Smoke-test on the first build before trusting the stack:

```bash
containerd --version
docker run --rm hello-world
kind load docker-image alpine:3.24 --name graphwise
```

If `kind load` fails, pin `containerd.io` to a known-good version in
`user-data.sh.tpl`, or move the `kind_version` pin.

**2. The marketplace image triple is unverified.** `resf` /
`rockylinux-x86_64` / `9-base` is a best guess — no `az` has been run against
it from this repo. All four fields are variables so you can correct them in
`terraform.tfvars` without editing the module. Verify with
`az vm image list --publisher resf --all -o table`.

**3. Root filesystem growth.** Azure marketplace images ship a small root
partition regardless of the disk you provision. cloud-init's growpart module
usually handles it but is silently skipped on LVM layouts. The bootstrap
re-asserts the grow defensively and prints `df -h /` — check that line in
`/var/log/bootstrap.log`. A 300 GiB disk with a 20 GiB root fills during the
first `helm install`.

**4. SELinux and firewalld.** Rocky ships SELinux *enforcing* and firewalld
*enabled*; AL2023 does neither. cloud-init sets SELinux permissive (KIND's
hostPath bind mount of `~/staging-data` needs it) and disables firewalld (it
fights Docker/kube-proxy's iptables rules). Both are logged. The NSG is the
network boundary.

**5. Deallocate/resume has not been exercised.** The whole park-and-resume
story rests on KIND containers surviving a deallocate/start cycle the same way
they survive an EC2 stop/start. Deallocate is a clean ACPI shutdown, so
`--restart=unless-stopped` plus `graphwise-cluster-resume.service` *should*
hold — but verify it on the first build, including
`poolparty-extractor-guard.sh` rebuilding the extraction index.

---

## Required shared-script changes

`scripts/cluster-bootstrap.sh` creates the `letsencrypt-prod` ClusterIssuer
with a Route 53 solver that authenticates via the EC2 instance role. On Azure
there is no role, so the issuer needs `accessKeyID` + `secretAccessKeySecretRef`.

**These edits are APPLIED.** All three are additive and capability-gated:

| File | Change |
|---|---|
| `scripts/cluster-bootstrap.sh` | Emits `accessKeyID` + `secretAccessKeySecretRef` (and creates the `route53-credentials` Secret in the `cert-manager` namespace) when static AWS creds are in the environment; otherwise unchanged instance-role form. |
| `scripts/preflight-reset-helm.sh` | §8 accepts static creds as a valid credential path instead of hard-failing on an unreachable AWS IMDS. Checks static first, so an Azure host never probes `169.254.169.254` at all. |
| `scripts/render-values.sh` | Refine points at upstream `ontotext/refine` on `x86_64`; `aarch64`/`arm64` fall through to the unchanged local-build branch. |

**The AWS path is semantically unchanged, and that was measured, not assumed.**
Extracting the *real* edited block and rendering it against `git HEAD`'s
version: the AWS output gains exactly one trailing blank line (where
`${ROUTE53_AUTH}` expands to nothing) plus one `echo` to stdout. Parsed as
YAML, the ClusterIssuer objects are identical. It is *not* byte-identical —
one blank line differs — but nothing a cluster sees changes.

### `GRAPHWISE_ROUTE53_AUTH`

The capability check has one false-positive mode worth knowing about: an
operator on an EC2 host who has exported AWS keys into their shell for an
unrelated reason (say the Bedrock pair) would silently get a ClusterIssuer
authenticating with those keys instead of the instance role — and if they lack
`route53:ChangeResourceRecordSets`, DNS-01 fails with `AccessDenied` and the
wildcard cert never issues. Expensive to debug from the symptom.

So `cluster-bootstrap.sh` and `preflight-reset-helm.sh` both honour an override:

| Value | Behaviour |
|---|---|
| `auto` *(default)* | Use static creds if present, else the instance role |
| `static` | Force static creds; exit 1 with a clear message if absent |
| `instance-role` | Force IMDSv2, ignoring any exported keys |

```bash
GRAPHWISE_ROUTE53_AUTH=instance-role ./scripts/cluster-bootstrap.sh
```

Both scripts read the same variable, so the preflight always diagnoses the path
bootstrap will actually take.

### Rotating the Route 53 key

`cluster-bootstrap.sh` creates the `route53-credentials` Secret in the
`cert-manager` namespace from whatever is in the environment at the time it
runs. Editing `~/.graphwise-route53.env` afterwards does **not** update the
Secret — nothing watches that file. To rotate:

```bash
$EDITOR ~/.graphwise-route53.env       # new key pair
source /etc/profile.d/graphwise.sh     # or just open a fresh login shell
./scripts/cluster-bootstrap.sh         # re-applies the Secret idempotently
```

`reset-helm.sh` does **not** re-run bootstrap and does not touch the
`cert-manager` namespace, so a normal reset cycle leaves both the Secret and
the issued wildcard cert intact — which is the intended behaviour (it is what
preserves the Let's Encrypt rate-limit budget).

The alternative — shipping a script here that overwrites the ClusterIssuer
*after* `cluster-bootstrap.sh` runs — was rejected: bootstrap creates the
wildcard `Certificate` immediately after the issuer, so every Azure deploy
would start a guaranteed-to-fail ACME order before the fix landed, burning
toward Let's Encrypt rate limits for no reason.

With these in place the Azure path is complete end to end on paper; what
remains is the live bring-up (Tasks 1-3 and 8 of the plan).

---

## Files

| File | Purpose |
|---|---|
| `main.tf` | RG, VNet + subnet, NSG, public IP (2 modes), NIC, VM, auto-shutdown |
| `variables.tf` | Every knob, with the reasoning inline |
| `outputs.tf` | DNS command, SSH, image pin, power commands, URLs |
| `versions.tf` | Provider pins (`azurerm ~> 4.0`) |
| `user-data.sh.tpl` | Rocky 9 cloud-init — the Azure twin of the AWS bootstrap |
| `terraform.tfvars.example` | Copy to `terraform.tfvars` and fill in |
| `.gitignore` | Folder-local; covers `route53-credentials.env` |
| `scripts/check-prereqs-azure.sh` | Laptop preflight — checks **both** `az` and `aws` |
| `scripts/azure-vm-power.sh` | Deallocate/start wrapper with the billing guard |
| `scripts/azure-manage-inbound-ip.sh` | NSG admin-CIDR management, dry-run by default |

### Contract with the rest of the repo

`user-data.sh.tpl` must keep these, or downstream scripts break:

- log at `/var/log/bootstrap.log`, mode 644
- last line contains **`Bootstrap complete`** — `deploy-stack.sh` gates on it
- `/etc/profile.d/graphwise.sh` exports `GRAPHWISE_APEX` / `ROUTE53_ZONE_ID` /
  `AWS_REGION` / `LE_EMAIL` — `cluster-bootstrap.sh` sources it
- repo at `~/gsb`, staging pad at `~/staging-data`, licenses in
  `~/gsb/files/licenses`
- `graphwise-cluster-resume.service` enabled
