#!/bin/bash
# Graphwise Stack -- EC2 first-boot bootstrap (cloud-init user-data).
# Runs ONCE as root on first boot. Outcome: AL2023 ARM64 host with
# Docker + KIND + kubectl + helm, single-node cluster up, repo cloned,
# ~/graphwise-secrets.yaml seeded with placeholders, /etc/profile.d/
# graphwise.sh exporting GRAPHWISE_APEX/ROUTE53_ZONE_ID/AWS_REGION.
# Operators run prep-scripts/cluster-bootstrap.sh next.
#
# Template substitutions: $${github_repo_url}, $${github_branch},
# $${hostname_fqdn}, $${n8n_encryption_key}, $${route53_zone_id},
# $${aws_region}. Other shell expansions need $$ to survive Terraform.
#
# AWS user-data has a 16KB limit (after base64-encode). Keep this
# file lean -- detailed rationale belongs in CLAUDE.md, not here.

set -euo pipefail
exec > >(tee /var/log/bootstrap.log | logger -t bootstrap) 2>&1

echo "=== Bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

TARGET_USER="ec2-user"
REPO_URL="${github_repo_url}"
HOSTNAME_FQDN="${hostname_fqdn}"

# Pinned tool versions. Bump deliberately; re-test the whole flow.
KIND_VERSION="v0.30.0"
KUBECTL_VERSION="v1.33.4"
HELM_VERSION="v3.17.0"

# OS patches + packages (Docker, KIND networking deps, helper tools).
dnf upgrade -y --refresh
dnf install -y docker git jq bind-utils conntrack-tools ethtool socat \
    iproute httpd-tools tar gzip ca-certificates rsync python3 python3-pip htop

# sshd: bump queue limits + force internal-sftp.
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

# Docker daemon + ec2-user in docker group (KIND/kubectl no-sudo).
systemctl enable --now docker
usermod -aG docker "$TARGET_USER"

# kind / kubectl / helm (ARM64, pinned versions).
ARCH="arm64"
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

# System-wide env vars (apex hostname + Route 53 zone + region +
# LE ACME contact email). All consumed by cluster-bootstrap.sh
# (cert-manager ClusterIssuer needs LE_EMAIL; the DNS-01 solver
# needs ROUTE53_ZONE_ID + AWS_REGION). cluster-bootstrap.sh
# auto-sources this file at the top so operators never have to
# remember the `source /etc/profile.d/graphwise.sh` dance.
cat > /etc/profile.d/graphwise.sh <<EOF
export GRAPHWISE_APEX="${hostname_fqdn}"
export ROUTE53_ZONE_ID="${route53_zone_id}"
export AWS_REGION="${aws_region}"
export LE_EMAIL="${le_email}"
EOF
chmod 644 /etc/profile.d/graphwise.sh

# Systemd service: auto-resume the KIND cluster on every EC2 boot.
# On AMI-seeded boots KIND containers are stopped; this brings them back
# without any operator action. On first-boot (no cluster yet) the
# --if-exists flag makes cluster-resume.sh exit 0 gracefully.
# cluster-bootstrap.sh self-heals the docker-group race so no manual
# `exec newgrp docker` is needed either.
cat > /etc/systemd/system/graphwise-cluster-resume.service <<'SVCEOF'
[Unit]
Description=Graphwise KIND cluster auto-resume on EC2 restart
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=ec2-user
ExecStart=/home/ec2-user/gsb/scripts/cluster-resume.sh --if-exists
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

# kubeconfig + aliases for ec2-user shells.
if ! grep -q "KUBECONFIG=" "/home/$TARGET_USER/.bashrc" 2>/dev/null; then
    cat >> "/home/$TARGET_USER/.bashrc" <<'RCEOF'

export KUBECONFIG="$HOME/.kube/config"
alias k=kubectl
alias kga='kubectl get all --all-namespaces'
alias showpods='kubectl get pods -A'
alias bootlog='tail -f /var/log/bootstrap.log'
RCEOF
    chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.bashrc"
fi

# Clone the repo + bring up the KIND cluster as ec2-user.
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
# Python dependencies (system-wide, available to all prep-scripts on this host).
pip3 install --ignore-installed -r "/home/$TARGET_USER/gsb/requirements.txt"

# Per-deployment secrets overlay -- single source of truth for ALL
# operator-supplied secrets. EC2-local; never tracked in git.
# reset-helm.sh auto-includes via -f and reads top-level maven block.
# prep-scripts/laptop/push-config.sh round-trips this across rebuilds.
#
# Loaded DYNAMICALLY: if the operator's real graphwise-secrets.yaml sits next
# to the terraform files, Terraform inlines it (base64) and we write it
# verbatim -- the same "terraform apply writes it" path as n8n.txt/licenses.
# Only when it is absent (brand-new stack) do we fall back to a fill-in-the-
# blanks placeholder carrying the Terraform-generated n8n encryption key.
SECRETS_FILE="/home/$TARGET_USER/graphwise-secrets.yaml"
if [ -n "${graphwise_secrets_b64}" ]; then
    printf '%s' "${graphwise_secrets_b64}" | base64 -d > "$SECRETS_FILE"
else
    cat > "$SECRETS_FILE" <<EOF
# All operator-supplied secrets for one graphwise-stack deployment.
# EC2-local; never committed. Push/pull via scripts/laptop/push-config.sh.

maven:
  user: ""                  # FILL IN: Graphwise maven user
  pass: ""                  # FILL IN: Graphwise maven password

graphrag-secrets:
  awsCredentials:           # SETUP step 4b graphrag-bedrock IAM user
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
mkdir -p "/home/$TARGET_USER/staging-data"
chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/staging-data"
chmod 755 "/home/$TARGET_USER/staging-data"

# Operator-supplied files that are gitignored (so they do NOT ride the clone),
# inlined as base64 by Terraform's templatefile() and written here -- same
# "terraform apply writes it" method as graphwise-secrets.yaml above. Each base64
# var is referenced ONCE (via _wb64) to keep user-data under the 16KB cap; an
# absent source file renders as an empty var and is skipped.
_wb64() {  # _wb64 <base64> <dest>  -- decode to dest (mode 600) if non-empty
    [ -n "$1" ] || return 0
    printf '%s' "$1" | base64 -d > "$2"
    chown "$TARGET_USER:$TARGET_USER" "$2"
    chmod 600 "$2"
}
_wb64 "${n8n_txt_b64}" "/home/$TARGET_USER/n8n.txt"

# License blobs -> ~/gsb/files/licenses/ (where prep-scripts/install-licenses.sh
# reads them: REPO_ROOT/files/licenses). The gsb clone exists by now.
mkdir -p "/home/$TARGET_USER/gsb/files/licenses"
_wb64 "${poolparty_key_b64}"   "/home/$TARGET_USER/gsb/files/licenses/poolparty.key"
_wb64 "${graphdb_license_b64}" "/home/$TARGET_USER/gsb/files/licenses/graphdb.license"
_wb64 "${uv_license_key_b64}"  "/home/$TARGET_USER/gsb/files/licenses/uv-license.key"
chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/gsb/files" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Optional: fully automated deploy (uncomment to run without operator input).
# Requires all operator files to be present in the terraform folder so that
# Terraform inlines them above (secrets, licenses). When commented out,
# operators run prep-scripts/deploy-stack.sh manually after first SSH login.
# ---------------------------------------------------------------------------
# SUBDOMAIN="$${HOSTNAME_FQDN%%.*}"
# BASE_DOMAIN="$${HOSTNAME_FQDN#*.}"
# sudo -u "$TARGET_USER" -i bash -c \
#     "cd ~/gsb && ./prep-scripts/deploy-stack.sh \"$$SUBDOMAIN\" \"$$BASE_DOMAIN\""

# Sentinel for /etc/profile.d/graphwise-hint.sh (login-time hint silences once present).
touch /var/lib/cloud/graphwise-bootstrap-complete

echo "=== Bootstrap complete at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
