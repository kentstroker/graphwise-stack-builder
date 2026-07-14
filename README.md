# Graphwise Stack Builder

A **Helm-on-KIND** deployment of the Graphwise / Ontotext **PoolParty** ecosystem plus the **GraphRAG** chatbot suite, running on a single **AWS EC2** instance (Amazon Linux 2023, Docker, single-node KIND cluster). Every app is reachable over HTTPS on its own subdomain via ingress-nginx + cert-manager + Let's Encrypt.

It is a **demo / evaluation** environment — not production-ready (default passwords, single-replica services, no HA or hardening). It is built primarily for internal use by Graphwise field presales engineers, and published MIT-licensed (AS-IS, no warranty, no support) so customers, partners, and the semantic-web community can reference it when standing up their own evaluation stacks.

## What's here

| Path | What it is |
|---|---|
| `charts/` | The umbrella Helm chart — PoolParty, GraphDB ×2, add-ons, console, Keycloak — plus the vendored GraphRAG charts |
| `infra/terraform-example/` | The end-user kit: a self-contained Terraform module that provisions the EC2 host and brings the cluster up |
| `scripts/` | EC2-side lifecycle scripts (bootstrap, deploy, validate, stop/start, …) |
| `STACK-BUILDER.md` | **The complete operator guide** (also rendered as `STACK-BUILDER.pdf`) |
| `TERRAFORM_NOTES.md` | Terraform module reference (also rendered as `TERRAFORM_NOTES.pdf`) |

## 📖 Read the full guide

**For everything — architecture, prerequisites, AWS/DNS setup, deploy, day-2 lifecycle, app URLs & credentials, and a per-script reference appendix — see [STACK-BUILDER.md](STACK-BUILDER.md)** (or the PDF).

For the Terraform module internals and `user-data.sh.tpl` bootstrap sequence, see [TERRAFORM_NOTES.md](TERRAFORM_NOTES.md).

## License

MIT — see [LICENSE](LICENSE). This repo ships **without** credentials or license files: you supply your own AWS account, a Route 53-hosted domain, and Graphwise licenses (`poolparty.key`, `graphdb.license`, `uv-license.key` + Maven registry credentials — contact `support@graphwise.ai`).
