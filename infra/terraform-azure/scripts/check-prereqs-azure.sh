#!/usr/bin/env bash
# check-prereqs-azure.sh -- laptop pre-flight for the AZURE deploy path.
#
# Read-only. Verifies the tools, cloud auth, key material, and local files
# that `terraform apply` and the post-provision steps depend on. Run it from
# anywhere; it locates the module relative to its own path.
#
#   ./scripts/check-prereqs-azure.sh
#
# WHY IT CHECKS BOTH CLOUDS: the Azure path still needs AWS. DNS stays in
# Route 53 (cert-manager's DNS-01 solver) and the LLM stays on Bedrock
# (PoolParty's Taxonomy Advisor + graphrag-components embeddings). So the
# operator needs `az` for the VM and `aws` for DNS -- this is not a swap of
# one CLI for the other. See README.md -> Why Route 53 stays.
#
# bash 3.2 compatible (macOS built-in bash). Note the ${arr[@]+"${arr[@]}"}
# guard idiom used for arrays under `set -u` -- see CLAUDE.md.

set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
    GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RED=$(printf '\033[31m')
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""
fi

FAILURES=0
WARNINGS=0

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

check_cmd() {  # check_cmd <binary> <label> <install-hint>
    if command -v "$1" >/dev/null 2>&1; then
        ok "$2 $DIM($(command -v "$1"))$RESET"
    else
        bad "$2 not found -- $3"
    fi
}

# ---------------------------------------------------------------------------
section "Required CLI tools"
# ---------------------------------------------------------------------------
check_cmd terraform "Terraform"  "install: brew install terraform"
check_cmd az        "Azure CLI"  "install: brew install azure-cli"
check_cmd aws       "AWS CLI"    "install: brew install awscli  (still needed -- DNS is Route 53)"
check_cmd jq        "jq"         "install: brew install jq"
check_cmd ssh       "ssh"        "ships with macOS"
check_cmd dig       "dig"        "install: brew install bind  (used to verify DNS after apply)"

if command -v terraform >/dev/null 2>&1; then
    TF_VER="$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || true)"
    [ -n "$TF_VER" ] && ok "Terraform version $TF_VER $DIM(module requires >= 1.5.0)$RESET"
fi

# ---------------------------------------------------------------------------
section "Azure authentication"
# ---------------------------------------------------------------------------
if command -v az >/dev/null 2>&1; then
    AZ_ACCOUNT="$(az account show --query '[name, id]' -o tsv 2>/dev/null | tr '\n' ' ' || true)"
    if [ -n "$AZ_ACCOUNT" ]; then
        ok "az authenticated -- $AZ_ACCOUNT"
        printf '    %sPaste the id above into terraform.tfvars as subscription_id%s\n' "$DIM" "$RESET"
    else
        bad "az installed but not authenticated -- run: az login"
    fi
else
    warn "skipped (az not installed)"
fi

# ---------------------------------------------------------------------------
section "AWS authentication (Route 53 DNS + Bedrock)"
# ---------------------------------------------------------------------------
if command -v aws >/dev/null 2>&1; then
    AWS_IDENT="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
    if [ -n "$AWS_IDENT" ]; then
        ok "aws authenticated -- $AWS_IDENT"
        printf '    %sNeeded to create the two Route 53 A records after apply%s\n' "$DIM" "$RESET"
    else
        warn "aws installed but not authenticated -- run: aws configure"
        printf '    %sYou can still apply, but you will not be able to create the DNS records%s\n' "$DIM" "$RESET"
    fi
else
    warn "skipped (aws not installed) -- you will need it for the Route 53 A records"
fi

# ---------------------------------------------------------------------------
section "SSH key material"
# ---------------------------------------------------------------------------
# Resolve ssh_public_key_path out of terraform.tfvars when present, else the
# module default. Deliberately a plain grep rather than `terraform console`
# so this stays runnable before `terraform init`.
PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"
if [ -f "$MODULE_DIR/terraform.tfvars" ]; then
    TFVARS_KEY="$(grep -E '^[[:space:]]*ssh_public_key_path[[:space:]]*=' "$MODULE_DIR/terraform.tfvars" 2>/dev/null \
                  | head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || true)"
    [ -n "$TFVARS_KEY" ] && PUBKEY_PATH="$TFVARS_KEY"
fi
PUBKEY_PATH="${PUBKEY_PATH/#\~/$HOME}"
PRIVKEY_PATH="${PUBKEY_PATH%.pub}"

if [ -f "$PUBKEY_PATH" ]; then
    ok "public key present -- $PUBKEY_PATH"
else
    bad "public key NOT found at $PUBKEY_PATH -- generate one: ssh-keygen -t ed25519 -f ${PRIVKEY_PATH}"
fi

if [ -f "$PRIVKEY_PATH" ]; then
    PERMS="$(stat -f '%Lp' "$PRIVKEY_PATH" 2>/dev/null || stat -c '%a' "$PRIVKEY_PATH" 2>/dev/null || echo "")"
    if [ "$PERMS" = "600" ] || [ "$PERMS" = "400" ]; then
        ok "private key present with $PERMS perms -- $PRIVKEY_PATH"
    else
        warn "private key perms are $PERMS -- ssh will refuse it. Fix: chmod 600 $PRIVKEY_PATH"
    fi
else
    bad "private key NOT found at $PRIVKEY_PATH -- ssh/scp to the VM will not work"
fi

# ---------------------------------------------------------------------------
section "Module files"
# ---------------------------------------------------------------------------
if [ -f "$MODULE_DIR/terraform.tfvars" ]; then
    ok "terraform.tfvars present"
    if grep -q "CHANGEME" "$MODULE_DIR/terraform.tfvars" 2>/dev/null; then
        bad "terraform.tfvars still contains CHANGEME placeholders -- fill them in before apply"
        grep -n "CHANGEME" "$MODULE_DIR/terraform.tfvars" | sed 's/^/      /'
    fi
else
    bad "terraform.tfvars missing -- copy it: cp terraform.tfvars.example terraform.tfvars"
fi

R53_ENV="$MODULE_DIR/route53-credentials.env"
if [ -f "$R53_ENV" ]; then
    MISSING_KEYS=""
    for k in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION; do
        grep -qE "^${k}=." "$R53_ENV" || MISSING_KEYS="$MISSING_KEYS $k"
    done
    if [ -z "$MISSING_KEYS" ]; then
        ok "route53-credentials.env present with all three keys"
    else
        bad "route53-credentials.env is missing:$MISSING_KEYS"
    fi
else
    bad "route53-credentials.env missing -- cert-manager will have no way to solve the DNS-01"
    printf '    %sCreate an IAM user scoped to route53:GetChange + ChangeResourceRecordSets%s\n' "$DIM" "$RESET"
    printf '    %s+ ListResourceRecordSets on your ONE hosted zone, then write three lines:%s\n' "$DIM" "$RESET"
    printf '    %s  AWS_ACCESS_KEY_ID=... / AWS_SECRET_ACCESS_KEY=... / AWS_REGION=...%s\n' "$DIM" "$RESET"
fi

if [ -f "$MODULE_DIR/graphwise-secrets.yaml" ]; then
    ok "graphwise-secrets.yaml present (will be inlined into cloud-init)"
else
    warn "graphwise-secrets.yaml absent -- cloud-init writes a fill-in-the-blanks placeholder"
fi

LIC_DIR="$MODULE_DIR/files/licenses"
for lic in poolparty.key graphdb.license uv-license.key; do
    if [ -f "$LIC_DIR/$lic" ]; then
        ok "license present -- files/licenses/$lic"
    else
        warn "license absent -- files/licenses/$lic (that product will not start)"
    fi
done

# ---------------------------------------------------------------------------
section "Azure-specific reminders (not checkable from here)"
# ---------------------------------------------------------------------------
cat <<'REMINDER'
  - Marketplace terms: Rocky is a plan image and needs a ONE-TIME accept per
    subscription, or apply fails with "Legal terms have not been accepted":
      az vm image terms accept --publisher resf --offer rockylinux-x86_64 --plan 9-base
  - VM size availability is regional. Confirm before apply:
      az vm list-skus --location <location> --size Standard_E8 --output table
  - Public IP: create it ONCE in a separate, long-lived resource group.
    terraform destroy deletes this deployment's whole resource group.
  - Parking the stack: use `az vm deallocate`, NEVER `az vm stop` or
    `sudo shutdown`. A merely-Stopped Azure VM keeps billing for compute.
REMINDER

# ---------------------------------------------------------------------------
printf '\n%s' "$BOLD"
if [ "$FAILURES" -gt 0 ]; then
    printf 'RESULT: %d blocking issue(s), %d warning(s)%s\n' "$FAILURES" "$WARNINGS" "$RESET"
    exit 1
fi
printf 'RESULT: ready to apply (%d warning(s))%s\n' "$WARNINGS" "$RESET"
