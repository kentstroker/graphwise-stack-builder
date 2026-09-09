# Graphwise Stack Builder

A **Helm-on-KIND** deployment of the Graphwise / Ontotext **PoolParty** ecosystem plus the **GraphRAG** chatbot suite, running on a single cloud instance (Docker + a single-node KIND cluster). Every app is reachable over HTTPS on its own subdomain via ingress-nginx + cert-manager + Let's Encrypt.

Two deployment paths ship: **AWS EC2** (Amazon Linux 2023) is the default and most-travelled one, and **Azure VM** is a self-contained alternative. DNS and certificate issuance go through Route 53 in both cases.

It is a **demo / evaluation** environment — not production-ready (default passwords, single-replica services, no HA or hardening). A personal project by Kent Stroker — not a Graphwise product, and not affiliated with, endorsed by, or supported by Graphwise or Ontotext. Published under the Apache License 2.0 (AS-IS, no warranty, no support — see [NOTICE](NOTICE) for what the license does and does not cover) so customers, partners, and the semantic-web community can reference it when standing up their own evaluation stacks.

## What's here

| Path | What it is |
|---|---|
| `charts/` | The umbrella Helm chart — PoolParty, GraphDB ×2, add-ons, console, Keycloak — plus the vendored GraphRAG charts |
| `infra/terraform-aws/` | Self-contained Terraform module that provisions the EC2 host and brings the cluster up — the default path |
| `infra/terraform-azure/` | The same stack on an Azure VM instead of EC2; has its own [README](infra/terraform-azure/README.md) |
| `scripts/` | Instance-side lifecycle scripts (bootstrap, deploy, validate, stop/start, …) |
| `STACK-BUILDER.md` | **The complete operator guide** |
| `TERRAFORM_NOTES.md` | Terraform module reference |

## 📖 Read the full guide

**For everything — architecture, prerequisites, AWS/DNS setup, deploy, day-2 lifecycle, app URLs & credentials, and a per-script reference appendix — see [STACK-BUILDER.md](STACK-BUILDER.md).**

Deploying on Azure instead? Start with [infra/terraform-azure/README.md](infra/terraform-azure/README.md), which covers only the differences; STACK-BUILDER.md still applies from the cluster layer up.

For the Terraform module internals and `user-data.sh.tpl` bootstrap sequence, see [TERRAFORM_NOTES.md](TERRAFORM_NOTES.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE). [NOTICE](NOTICE) covers what that license does not extend to: the proprietary Graphwise/Ontotext product binaries, the third-party images the stack pulls, and the trademarks involved. This repo ships **without** credentials or license files: you supply your own AWS (or Azure) account, a Route 53-hosted domain, and Graphwise licenses (`poolparty.key`, `graphdb.license`, `uv-license.key` + Maven registry credentials — contact `support@graphwise.ai`).
