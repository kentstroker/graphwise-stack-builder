# Security Assessment — Graphwise Stack Builder
**Date:** 2026-07-02
**Scope:** All committed code, templates, scripts, and gitignore effectiveness
**Status:** LOCAL ONLY — gitignored, never push

---

## Part 1: Credential Exposure in Git

**Verdict: No credentials committed. Gitignore is sound.**

Three real-secret files were found on disk and all three are properly gitignored:

| File | Gitignore Rule | Status |
|---|---|---|
| `infra/terraform-subdomain/graphwise-secrets.yaml` | `.gitignore:199 — **/graphwise-secrets.yaml` | **NOT tracked** |
| `infra/terraform-subdomain/terraform.tfvars` | `.gitignore:158 — **/terraform.tfvars` | **NOT tracked** |
| `infra/terraform-subdomain/n8n.txt` | `.gitignore:200 — **/n8n.txt` | **NOT tracked** |

Verification: `git ls-files` returned empty for all three — they have never entered the index.

All five `AKIA` hits in git history (`git log -S "AKIA"`) are placeholder text in documentation: `AKIA<your access key id>`, `AKIA...your-terraform-demo-key...`, `FILL IN: graphrag-bedrock AKIA...` — no real key digits after the prefix.

No `.tfstate` files were found anywhere in the repo.

---

## Part 2: Content of On-Disk Secret Files (Local, Never Committed)

`n8n.txt` contains more than just the n8n encryption key — it also holds the runtime AWS
keys (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) and an `EXTRACTOR_AUTH=Basic …` value
whose decoded value is the PoolParty superadmin credential. These are properly gitignored
and local-only, but:

- **Rebuild action**: The AWS IAM key pair in `n8n.txt` (and `graphwise-secrets.yaml`)
  should be deactivated in IAM after the stack is destroyed — they're scoped to that
  stack's IAM user and won't be reused.
- **Superadmin password** (`EXTRACTOR_AUTH` decode) is a non-`rdf#rocks` credential.
  Confirm it isn't reused across other accounts (AWS root, personal logins, etc.).

---

## Part 3: Committed Sensitive Data — n8n DB Tarball

**Severity: LOW (by design, mitigated by encryption)**

`infra/terraform-subdomain/files/n8n-pg-dumpall.sql.tar.gz` **is tracked in git**
(committed intentionally per CLAUDE.md to ship the known-good workflow DB, ~18MB).
n8n encrypts all stored credentials using `N8N_ENCRYPTION_KEY`.

**Risk model:**
- Tarball in git + encryption key gitignored = inert without the key
- Anyone with both the tarball AND the key can decrypt stored n8n credentials
- The key lives only in gitignored `n8n.txt` and Terraform state (also gitignored)

**Recommendation:** Acceptable for a demo repo. For a shared-team repo, move the tarball
to a private S3 bucket and pull at boot from `user-data.sh.tpl`.

---

## Part 4: Hardcoded Demo Defaults (By Design)

**Severity: INFO — Expected, must rotate before any customer-facing use**

| Location | Credential | Design intent |
|---|---|---|
| `charts/graphwise-stack/values.yaml` (12+ occurrences) | `rdf#rocks` | Postgres, Keycloak clients, MySQL, conversation secret, ingress basic-auth |
| `charts/keycloak-realms/values.yaml:30` | `alice123`, `bob123` | Demo user credentials |
| `charts/console/values.yaml:56` | `demo / rdf#rocks` | Basic-auth display string |

These are the documented default-password convention from CLAUDE.md. Appropriate for a
demo repo. **Rotate all before any production use or customer hand-off.**

---

## Part 5: Personal Hostname in Templates — RESOLVED

**Severity: LOW → FIXED in commit de273aa**

Two Keycloak realm templates formerly contained `stroker.semantic-proof.com` as a
find-and-replace source string. Those lines were dead code (the hostname was absent from
all realm JSON files) and exposed the developer's personal subdomain in the public repo.
Both lines were removed in the security cleanup commit.

---

## Part 6: Container / Kubernetes Security

### 6a. No NetworkPolicy — East-West Traffic Unrestricted
**Severity: MEDIUM**

No `NetworkPolicy` resources exist in any chart. Every pod in `graphwise`, `graphrag`,
`keycloak`, `graphdb`, `federated`, and `cert-manager` namespaces can reach every other
pod on any port. A compromised container could query the Keycloak admin API, write to
GraphDB, or reach the n8n API.

**Accepted for demo.** For production, add namespace-level egress policies with explicit
allow rules per service.

### 6b. IMDSv2 Hop Limit = 3 — Pods Can Access Instance Metadata
**Severity: MEDIUM**

`http_put_response_hop_limit = 3` is required for KIND (EC2 → Docker bridge → KIND network
= 3 hops). This means any pod can call the EC2 IMDS and obtain the instance IAM role
credentials (which have Route 53 permissions).

**Mitigations in place:** IMDSv2 enforced (`http_tokens = "required"`); Route 53 policy
scoped to one hosted-zone ARN.

**Accepted for demo.** For production, use IRSA on EKS instead of KIND.

### 6c. `automountServiceAccountToken` in Vendor GraphRAG Charts
**Severity: LOW**

Vendor `charts/vendor/graphrag*/` pods do not explicitly disable service account token
automounting. Track for the next vendor version update.

### 6d. hostPath Mount for Staging Data
**Severity: LOW (intentional)**

`hostPath: /staging-data` mounts the EC2 host path into the cluster. Ensure this directory
on the EC2 host never contains credential files — it should hold only demo graph data.

---

## Part 7: In-Cluster Cleartext HTTP

**Severity: LOW (expected, in-cluster only)**

All service-to-service traffic uses HTTP internally:

| Service | URL pattern |
|---|---|
| Keycloak | `http://keycloak-service.keycloak:8080` |
| Elasticsearch | `http://graphwise-stack-poolparty-elasticsearch.graphwise:9200` |
| RDF4J | `http://rdf4j:8080/rdf4j-server` |
| Keycloak OIDC JWK URI (graphrag-conversation) | `http://keycloak:8080/realms/graphrag/protocol/openid-connect/certs` |

All are intra-cluster only. mTLS requires a service mesh (Istio/Linkerd), out of scope for
a demo stack.

---

## Part 8: IAM and Terraform

### 8a. `route53:GetChange` on Wildcard Resource — No Issue
The Route 53 IAM policy scopes record-change permissions to a single hosted-zone ARN.
`route53:GetChange` must use `arn:aws:route53:::change/*` — change IDs aren't known in
advance. Correct per AWS documentation; no change needed.

### 8b. Local Terraform State Only
**Severity: LOW (acceptable for demo)**

No remote state backend. State lives on the operator's laptop, is gitignored, and will
contain the `random_id.n8n_encryption_key`. For a shared-team deployment, migrate to an
S3 backend with DynamoDB locking and bucket encryption.

---

## Part 9: Shell Script Security

**Verdict: CLEAN**

- No `curl | bash` or `eval $(curl ...)` patterns
- No `eval` with user-controlled input
- No `rm -rf $UNQUOTED_VAR`
- No `chmod 777`
- All curl calls use safety flags (`-fsSL`, `--fail`)
- IMDSv2 correctly implemented (PUT token, then GET with header)
- Bash 3.2 array guard (`${arr[@]+"${arr[@]}"}`) in place in `stack-scp.sh`

---

## Summary Table

| Finding | Severity | Status |
|---|---|---|
| Credentials in git | NONE | Clean |
| AKIA pattern in git history | NONE | All placeholders |
| Real keys in local `n8n.txt` | LOCAL ONLY | Rotate on rebuild |
| Superadmin password in `n8n.txt` | LOCAL ONLY | Audit reuse |
| n8n DB tarball committed | LOW | Accepted; inert without key |
| Demo defaults (`rdf#rocks`, `alice123`) | INFO | Rotate for prod |
| Personal hostname in templates | LOW | **Fixed — de273aa** |
| No NetworkPolicy | MEDIUM | Accepted for demo |
| IMDS hop_limit=3 | MEDIUM | Accepted for KIND |
| automountServiceAccountToken | LOW | Track for next vendor update |
| hostPath staging data | LOW | Keep path credential-free |
| In-cluster HTTP | LOW | Expected; accepted for demo |
| `route53:GetChange` wildcard | LOW | Correct; no change |
| Local Terraform state | LOW | Acceptable solo-operator |
| Shell scripts | NONE | Clean |

---

## Pre-Rebuild Checklist

- [ ] Deactivate the IAM key pair from `n8n.txt` in the AWS Console after stack destroy
- [ ] Audit that the superadmin password (EXTRACTOR_AUTH decode) isn't reused elsewhere
- [ ] Personal hostname fix is committed (de273aa) — no further action
