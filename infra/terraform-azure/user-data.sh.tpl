#!/bin/bash
# Graphwise Stack -- AZURE VM first-boot bootstrap (cloud-init custom_data).
#
# Runs ONCE as root on first boot. Outcome: a Rocky Linux 9 x86_64 host with
# Docker + KIND + kubectl + helm, a single-node KIND cluster up, the repo
# cloned to ~/gsb, ~/graphwise-secrets.yaml seeded, and /etc/profile.d/
# graphwise.sh exporting GRAPHWISE_APEX / ROUTE53_ZONE_ID / LE_EMAIL plus
# the static Route 53 IAM key pair. Operators run scripts/deploy-stack.sh next.
#
# This is the Azure twin of infra/terraform-example/user-data.sh.tpl. The
# contract with the rest of the repo is IDENTICAL and must stay that way:
#   - log at /var/log/bootstrap.log, mode 644
#   - last line contains "Bootstrap complete"  <-- scripts/deploy-stack.sh
#     gates on this exact marker before it will run
#   - /etc/profile.d/graphwise.sh exports GRAPHWISE_APEX / ROUTE53_ZONE_ID /
#     AWS_REGION / LE_EMAIL          <-- scripts/cluster-bootstrap.sh sources it
#   - repo at ~/gsb, staging pad at ~/staging-data, licenses in ~/gsb/files/licenses
#   - graphwise-cluster-resume.service enabled
#
# WHAT DIFFERS FROM THE AWS SCRIPT, and why (details in README.md):
#   1. Docker comes from the Docker CE repo, not the distro. Rocky has no
#      `docker` package. This is the highest-risk difference in the port --
#      see the containerd note at the install site.
#   2. firewalld is disabled. Rocky ships it enabled; it fights Docker/KIND's
#      iptables rules. The NSG is the firewall.
#   3. SELinux is set permissive. Rocky ships it enforcing; KIND's hostPath
#      bind mount of ~/staging-data into the node container needs it relaxed.
#   4. EPEL is enabled (htop lives there on Rocky, not in AppStream).
#   5. ARCH is amd64, not arm64.
#   6. The root filesystem is explicitly grown to the full OS disk.
#   7. A static AWS key pair is written for cert-manager's Route 53 solver,
#      replacing the AWS module's EC2 instance role + IMDSv2 chain.
#
# Template substitutions (Terraform, NOT shell): $${github_repo_url},
# $${github_branch}, $${hostname_fqdn}, $${n8n_encryption_key},
# $${route53_zone_id}, $${le_email}, $${target_user}, $${kind_version},
# $${kubectl_version}, $${helm_version}, and the base64 file blobs.
# Any genuine shell $${VAR} expansion must be written with a doubled $$.
#
# Azure custom_data caps at 64 KB (vs AWS user_data's 16 KB), so there is
# headroom here -- but keep detailed rationale in README.md, not inline.

set -euo pipefail
exec > >(tee /var/log/bootstrap.log | logger -t bootstrap) 2>&1
chmod 644 /var/log/bootstrap.log 2>/dev/null || true

echo "=== Bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

TARGET_USER="${target_user}"
REPO_URL="${github_repo_url}"
HOSTNAME_FQDN="${hostname_fqdn}"

# The Azure Linux Agent + cloud-init's `users` module create the admin
# account before the shellscript stage runs, but the ordering is not
# contractual across images -- wait for it rather than assuming.
for _i in $(seq 1 30); do
    id "$TARGET_USER" >/dev/null 2>&1 && break
    echo "waiting for user $TARGET_USER to exist ($_i/30)..."
    sleep 2
done
id "$TARGET_USER" >/dev/null 2>&1 || { echo "FATAL: user $TARGET_USER never appeared"; exit 1; }

# Docker group FIRST -- before docker even installs. cloud-init runs for
# 10-15 min; adding the admin user to the docker group only after the
# package install (minutes in) means any SSH session opened before that --
# and any `sg docker` self-heal run early -- has no group to join and can't
# reach /var/run/docker.sock. Creating the group + adding the user within
# seconds of boot means a fresh login gets docker access almost immediately.
# The docker-ce package reuses this group; its socket is group-owned by it.
groupadd -f docker
usermod -aG docker "$TARGET_USER"

# Pinned tool versions, passed in from Terraform so they are one edit in
# terraform.tfvars rather than a fork of this file. Bump deliberately and
# re-test the whole flow.
KIND_VERSION="${kind_version}"
KUBECTL_VERSION="${kubectl_version}"
HELM_VERSION="${helm_version}"

# ---------------------------------------------------------------------------
# Rocky-specific host prep: firewalld off, SELinux permissive
# ---------------------------------------------------------------------------
# firewalld: Rocky/RHEL ship it enabled. It installs its own iptables/nftables
# rule set, which collides with the rules Docker and kube-proxy program --
# the classic symptom is pods that can reach the internet but not each other,
# or an ingress-nginx that binds :443 and still refuses connections. AL2023
# has no firewalld at all, which is why the AWS script never mentions it.
# The Azure NSG is the network boundary here; a host firewall adds nothing
# but failure modes for a single-tenant demo box.
systemctl disable --now firewalld 2>/dev/null || echo "  (firewalld not present -- nothing to disable)"

# SELinux: Rocky/RHEL ship it ENFORCING; AL2023 ships permissive. KIND bind-
# mounts /home/<user>/staging-data into the node container (see
# infra/kind/kind-config.yaml extraMounts) and containerd inside that node
# writes to the host filesystem -- both need labels that enforcing mode
# denies by default. Permissive still logs every denial to the audit log, so
# nothing is hidden; it just does not block. Set for the running kernel AND
# persisted for reboots.
setenforce 0 2>/dev/null || true
if [ -f /etc/selinux/config ]; then
    sed -i -E 's/^SELINUX=(enforcing|disabled)/SELINUX=permissive/' /etc/selinux/config
fi

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
dnf upgrade -y --refresh
dnf install -y dnf-plugins-core

# EPEL: htop is not in Rocky's BaseOS/AppStream. Everything else below is.
dnf install -y epel-release || echo "  (epel-release unavailable -- htop may be skipped)"

# Docker CE. Rocky has NO `docker` package -- the distro ships podman, and
# the AWS script's `dnf install docker` has no equivalent here.
#
# !! HIGHEST-RISK LINE IN THE AZURE PORT !!
# The KIND pin (0.30.0 / node v1.33.4) exists because a KIND node whose
# containerd is NEWER than the host's breaks `kind load` -- KIND 0.32.0's
# node ships containerd 2.3.1 (config v4) which a 2.2.x host cannot read.
# On AL2023 the bundled docker package pins host containerd at 2.2.x, which
# is what makes that pin safe. Docker CE's containerd.io package version is
# an INDEPENDENT moving target, so the host/node relationship is no longer
# guaranteed by the distro. After first boot, verify with:
#     containerd --version
#     docker run --rm hello-world
#     kind load docker-image alpine:3.24 --name graphwise
# If `kind load` fails, pin containerd.io to a known-good version here
# (dnf install -y containerd.io-<ver>) or move the KIND pin.
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io

# KIND networking deps + helper tools -- same list as the AWS script.
# (`docker`, `git`, `tar`, `gzip`, `ca-certificates` come from above or base.)
dnf install -y git jq bind-utils conntrack-tools ethtool socat iproute \
    httpd-tools tar gzip ca-certificates rsync python3 python3-pip \
    cloud-utils-growpart gdisk
dnf install -y htop || echo "  (htop unavailable -- non-fatal)"

echo "=== containerd / docker versions (check against the KIND pin) ==="
containerd --version || true
docker --version || true

# ---------------------------------------------------------------------------
# Grow the root filesystem to the full OS disk
# ---------------------------------------------------------------------------
# Azure marketplace images ship a small root partition (typically 10-30 GiB)
# regardless of the disk size you provision. cloud-init's growpart module
# usually handles this, but it is silently skipped on LVM layouts and on
# some images -- and a 300 GiB disk with a 20 GiB root fills up during the
# first `helm install` (the KIND containerd image cache alone is tens of GiB).
# Re-assert it defensively; every step is tolerant of "nothing to do".
echo "=== Growing root filesystem ==="
ROOT_SRC="$(findmnt -no SOURCE / || true)"
if [ -n "$ROOT_SRC" ]; then
    case "$ROOT_SRC" in
        /dev/mapper/*)
            # LVM layout (RHEL's -lvm- SKUs). Extend the LV into free extents.
            lvextend -r -l +100%FREE "$ROOT_SRC" 2>&1 || echo "  (lvextend: nothing to do)"
            ;;
        *)
            ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)"
            ROOT_PART="$(echo "$ROOT_SRC" | grep -oE '[0-9]+$' || true)"
            if [ -n "$ROOT_DISK" ] && [ -n "$ROOT_PART" ]; then
                growpart "/dev/$ROOT_DISK" "$ROOT_PART" 2>&1 || echo "  (growpart: nothing to do)"
                xfs_growfs / 2>&1 || resize2fs "$ROOT_SRC" 2>&1 || echo "  (fs grow: nothing to do)"
            fi
            ;;
    esac
fi
df -h /

# ---------------------------------------------------------------------------
# sshd + sysctls
# ---------------------------------------------------------------------------
# sshd: bump queue limits + force internal-sftp (same as the AWS script --
# scp of the licenses/seed files opens many short-lived sessions).
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-graphwise.conf <<'SSHDEOF'
Subsystem sftp internal-sftp
LoginGraceTime 30
MaxStartups 100:30:200
SSHDEOF
sed -i -E 's|^(\s*Subsystem\s+sftp\s+/.*)$|# \1|' /etc/ssh/sshd_config
systemctl restart sshd

# Sysctls for KIND (ip_forward + raised inotify limits).
cat > /etc/sysctl.d/99-kind.conf <<'SYSCTLEOF'
net.ipv4.ip_forward = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
SYSCTLEOF
sysctl --system

# Docker daemon up.
systemctl enable --now docker
usermod -aG docker "$TARGET_USER"   # idempotent re-assert (belt-and-braces)

# ---------------------------------------------------------------------------
# kind / kubectl / helm (amd64, pinned versions)
# ---------------------------------------------------------------------------
# ARCH is amd64 here, not arm64. The x86_64 VM size is a deliberate choice,
# not a fallback: it also lets the stack pull ontotext/refine directly
# instead of using the bundled platform-independent dist workaround that
# exists only because that image is amd64-only on Docker Hub.
ARCH="amd64"
curl -fsSL -o /usr/local/bin/kind \
    "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-$ARCH"
chmod +x /usr/local/bin/kind
curl -fsSL -o /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl"
chmod +x /usr/local/bin/kubectl
curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz" \
    | tar -xz -C /tmp
mv "/tmp/linux-$ARCH/helm" /usr/local/bin/helm
chmod +x /usr/local/bin/helm
rm -rf "/tmp/linux-$ARCH"

# ---------------------------------------------------------------------------
# Static Route 53 credentials for cert-manager's DNS-01 solver
# ---------------------------------------------------------------------------
# This file is the Azure replacement for the AWS module's EC2 instance role.
# An Azure VM cannot assume an AWS IAM role, so the credential has to be
# static. It is written mode 600, owned by the admin user, and sourced by
# /etc/profile.d/graphwise.sh below -- which is what puts AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY / AWS_REGION into the environment that
# scripts/cluster-bootstrap.sh runs in.
#
# Scope the IAM user exactly as the AWS module's role policy does:
#   route53:GetChange                          on arn:aws:route53:::change/*
#   route53:ChangeResourceRecordSets           on this ONE hostedzone ARN
#   route53:ListResourceRecordSets             on this ONE hostedzone ARN
# Even if exfiltrated it can then only edit DNS for the single demo zone.
R53_ENV="/home/$TARGET_USER/.graphwise-route53.env"
if [ -n "${route53_credentials_b64}" ]; then
    printf '%s' "${route53_credentials_b64}" | base64 -d > "$R53_ENV"
    chown "$TARGET_USER:$TARGET_USER" "$R53_ENV"
    chmod 600 "$R53_ENV"
    echo "  ✓ Route 53 credentials written to $R53_ENV"
else
    echo "  !! NO Route 53 credentials supplied. cert-manager will not be able"
    echo "  !! to solve the DNS-01 challenge and the wildcard cert will NOT"
    echo "  !! issue -- every OIDC-dependent app will then fail at startup."
    echo "  !! Fix: write $R53_ENV by hand (mode 600) with AWS_ACCESS_KEY_ID,"
    echo "  !! AWS_SECRET_ACCESS_KEY and AWS_REGION lines, then re-run"
    echo "  !! scripts/cluster-bootstrap.sh."
fi

# ---------------------------------------------------------------------------
# System-wide env vars
# ---------------------------------------------------------------------------
# Consumed by scripts/cluster-bootstrap.sh, which auto-sources this file at
# the top so operators never have to remember the `source` dance. Note the
# AWS_REGION the ClusterIssuer needs comes from the Route 53 env file, not
# from a Terraform variable -- it is a property of the credential, so keeping
# them together means they can never drift apart.
#
# Side effect worth knowing: because the credential is exported into every
# login shell, a plain `aws route53 ...` on this box authenticates as the
# DNS-01 user. That is intentional (it makes the DNS records easy to fix
# from the VM), but it is NOT the Bedrock key -- those live only in the
# Kubernetes Secrets rendered from ~/graphwise-secrets.yaml.
cat > /etc/profile.d/graphwise.sh <<EOF
export GRAPHWISE_APEX="${hostname_fqdn}"
export ROUTE53_ZONE_ID="${route53_zone_id}"
export LE_EMAIL="${le_email}"
export GRAPHWISE_CLOUD="azure"

# Static IAM key pair for cert-manager's Route 53 DNS-01 solver (see
# infra/terraform-azure/README.md). Exports AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY and AWS_REGION when the file is present. Their
# presence is ALSO the signal scripts/cluster-bootstrap.sh uses to emit a
# static-credential ClusterIssuer instead of the AWS instance-role form.
if [ -f "\$HOME/.graphwise-route53.env" ]; then
    set -a
    . "\$HOME/.graphwise-route53.env"
    set +a
fi
EOF
chmod 644 /etc/profile.d/graphwise.sh

# ---------------------------------------------------------------------------
# Systemd service: auto-resume the KIND cluster on every VM boot
# ---------------------------------------------------------------------------
# Identical in shape to the AWS unit. On a deallocate/start cycle the KIND
# containers come back stopped; this brings them up and calls
# cluster-start.sh without any operator action. On first boot (no cluster
# yet) the --if-exists flag makes cluster-resume.sh exit 0 gracefully.
# (Quoted heredoc: bash expands nothing. Terraform still substitutes
# $${target_user} here -- templatefile() processes the whole file before
# bash ever sees it, so heredoc quoting does not shield it.)
cat > /etc/systemd/system/graphwise-cluster-resume.service <<'SVCEOF'
[Unit]
Description=Graphwise KIND cluster auto-resume on VM restart
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=${target_user}
ExecStart=/home/${target_user}/gsb/scripts/cluster-resume.sh --if-exists
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable graphwise-cluster-resume.service

# Login-time hint: cloud-init in progress; silent in the steady state.
cat > /etc/profile.d/graphwise-hint.sh <<'PHINT'
[ -t 1 ] || return 0
if [ ! -f /var/lib/cloud/graphwise-bootstrap-complete ]; then
    echo "[graphwise] cloud-init still running -- watch: sudo tail -f /var/log/bootstrap.log"
else
    _resume_state=$(systemctl is-active graphwise-cluster-resume.service 2>/dev/null || true)
    if [[ "$_resume_state" == "activating" ]]; then
        echo "[graphwise] KIND cluster resuming... (systemctl status graphwise-cluster-resume)"
    fi
fi
PHINT
chmod 644 /etc/profile.d/graphwise-hint.sh

# kubeconfig + aliases for the admin user's shells.
if ! grep -q "KUBECONFIG=" "/home/$TARGET_USER/.bashrc" 2>/dev/null; then
    cat >> "/home/$TARGET_USER/.bashrc" <<'RCEOF'

export KUBECONFIG="$HOME/.kube/config"
alias kp='kubectl get pods -A'
alias kga='kubectl get all --all-namespaces'
alias bootlog='tail -f /var/log/bootstrap.log'
RCEOF
    chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.bashrc"
fi

# ---------------------------------------------------------------------------
# Clone the repo + bring up the KIND cluster as the admin user
# ---------------------------------------------------------------------------
# Login shell so freshly-added docker-group membership is in effect.
sudo -u "$TARGET_USER" -i bash <<INNER
set -euo pipefail
cd "\$HOME"
[[ -d "gsb" ]] || git clone -b "${github_branch}" "$REPO_URL" gsb
cd gsb
if ! kind get clusters 2>/dev/null | grep -qx graphwise; then
    kind create cluster --name graphwise --config infra/kind/kind-config.yaml
fi
kubectl cluster-info --context kind-graphwise
kubectl get nodes
INNER

echo "=== pip3: installing Python dependencies ==="
pip3 install --ignore-installed -r "/home/$TARGET_USER/gsb/requirements.txt"

# ---------------------------------------------------------------------------
# Per-deployment secrets overlay
# ---------------------------------------------------------------------------
# Single source of truth for ALL operator-supplied secrets. VM-local; never
# tracked in git. reset-helm.sh auto-includes it via -f and reads the
# top-level maven block. push-config.sh / pull-config.sh round-trip it.
#
# Loaded DYNAMICALLY: if the operator's real graphwise-secrets.yaml sits
# next to the terraform files, Terraform inlines it (base64) and we write it
# verbatim. Only when absent do we fall back to a fill-in-the-blanks
# placeholder carrying the Terraform-generated n8n encryption key.
#
# NOTE the awsCredentials block below is the BEDROCK key pair (PoolParty's
# Taxonomy Advisor + graphrag-components embeddings), NOT the Route 53 key
# pair written above. They are separate IAM users with disjoint policies and
# must stay that way -- do not merge them.
SECRETS_FILE="/home/$TARGET_USER/graphwise-secrets.yaml"
if [ -n "${graphwise_secrets_b64}" ]; then
    printf '%s' "${graphwise_secrets_b64}" | base64 -d > "$SECRETS_FILE"
else
    cat > "$SECRETS_FILE" <<EOF
# All operator-supplied secrets for one graphwise-stack deployment.
# VM-local; never committed. Push/pull via scripts/push-config.sh.

maven:
  user: ""                  # FILL IN: Graphwise maven user
  pass: ""                  # FILL IN: Graphwise maven password

graphrag-secrets:
  awsCredentials:           # graphrag-bedrock IAM user (NOT the Route 53 one)
    region: "us-west-2"
    accessKeyId: ""         # FILL IN: AKIA...
    secretAccessKey: ""     # FILL IN
  n8nLicense:
    activationKey: ""       # FILL IN: n8n Enterprise key
  n8nEncryption:            # AUTO-GENERATED -- do not edit
    key: "${n8n_encryption_key}"
EOF
fi
chown "$TARGET_USER:$TARGET_USER" "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

# Staging-data landing pad for ingest uploads (rsync -> ~/staging-data/).
# infra/kind/kind-config.yaml bind-mounts this exact path into the KIND
# control-plane container, which is why admin_username defaults to ec2-user.
mkdir -p "/home/$TARGET_USER/staging-data"
chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/staging-data"
chmod 755 "/home/$TARGET_USER/staging-data"

# ---------------------------------------------------------------------------
# Operator-supplied gitignored files, inlined as base64 by Terraform
# ---------------------------------------------------------------------------
# Each base64 var is referenced ONCE (via _wb64); an absent source file
# renders as an empty var and is skipped.
_wb64() {  # _wb64 <base64> <dest>  -- decode to dest (mode 600) if non-empty
    [ -n "$1" ] || return 0
    printf '%s' "$1" | base64 -d > "$2"
    chown "$TARGET_USER:$TARGET_USER" "$2"
    chmod 600 "$2"
}
_wb64 "${n8n_txt_b64}" "/home/$TARGET_USER/n8n.txt"

# License blobs -> ~/gsb/files/licenses/ (where scripts/install-licenses.sh
# reads them: REPO_ROOT/files/licenses). The gsb clone exists by now.
mkdir -p "/home/$TARGET_USER/gsb/files/licenses"
_wb64 "${poolparty_key_b64}"   "/home/$TARGET_USER/gsb/files/licenses/poolparty.key"
_wb64 "${graphdb_license_b64}" "/home/$TARGET_USER/gsb/files/licenses/graphdb.license"
_wb64 "${uv_license_key_b64}"  "/home/$TARGET_USER/gsb/files/licenses/uv-license.key"
chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/gsb/files" 2>/dev/null || true

# Sentinel for /etc/profile.d/graphwise-hint.sh (login hint silences once present).
touch /var/lib/cloud/graphwise-bootstrap-complete
chmod 644 /var/log/bootstrap.log 2>/dev/null || true

# The marker below is load-bearing: scripts/deploy-stack.sh refuses to run
# until it can `grep -q "Bootstrap complete" /var/log/bootstrap.log`. Keep
# this as the last line and keep the wording exact.
echo "=== Bootstrap complete at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
