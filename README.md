# Graphwise Stack Builder

A **Helm-on-KIND** deployment of the Graphwise / Ontotext **PoolParty** ecosystem plus the **GraphRAG** chatbot suite, running on a single **AWS EC2** instance (Amazon Linux 2023, Docker, single-node KIND cluster). Every app is reachable over HTTPS on its own subdomain via ingress-nginx + cert-manager + Let's Encrypt.

It is a **demo / evaluation** environment — not production-ready (default passwords, single-replica services, no HA or hardening). A personal project by Kent Stroker — not a Graphwise product, and not affiliated with, endorsed by, or supported by Graphwise or Ontotext. Published under the Apache License 2.0 (AS-IS, no warranty, no support — see [NOTICE](NOTICE) for what the license does and does not cover) so customers, partners, and the semantic-web community can reference it when standing up their own evaluation stacks.

## Getting the kit

```bash
git clone --depth 1 https://github.com/kentstroker/graphwise-stack-builder.git
```

`--depth 1` gets you a ~2 MB clone instead of the ~151 MB a full clone with
history pulls down — plenty to deploy from. Drop the flag for a plain full
clone if you want the history too.

## What's here

| Path | What it is |
|---|---|
| `laptop-kit/` | **Start here — everything you run on your laptop:** the Terraform module and its 8 helper scripts, the PoolParty TTL authoring skill, and the n8n workflow seed |
| `docs/` | All documentation — `LAPTOP-KIT.md` to deploy, `STACK-BUILDER.md` for the full operator guide, `TERRAFORM_NOTES.md` for module internals |
| `charts/` | Runs on the EC2, arriving via cloud-init — the umbrella Helm chart (PoolParty, GraphDB ×2, add-ons, console, Keycloak) plus the vendored GraphRAG charts |
| `scripts/` | Runs on the EC2, arriving via cloud-init — lifecycle scripts (bootstrap, deploy, validate, stop/start, …) |
| `infra/kind/` | Runs on the EC2, arriving via cloud-init — KIND cluster config |
| `requirements.txt`, `requirements-ingest.txt` | Python dependencies installed on the EC2 for the stack scripts, and (optionally) for out-of-band ingest workflows |
| `LICENSE`, `NOTICE` | Apache License 2.0, and what it does and does not cover |

## 📖 Read the full guide

**Start with [docs/LAPTOP-KIT.md](docs/LAPTOP-KIT.md)** — the step-by-step walkthrough from "I have the repo" to "I have a running stack."

**For everything else — architecture, prerequisites, AWS/DNS setup, day-2 lifecycle, app URLs & credentials, and a per-script reference appendix — see [docs/STACK-BUILDER.md](docs/STACK-BUILDER.md).**

For the Terraform module internals and `user-data.sh.tpl` bootstrap sequence, see [docs/TERRAFORM_NOTES.md](docs/TERRAFORM_NOTES.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE). [NOTICE](NOTICE) covers what that license does not extend to: the proprietary Graphwise/Ontotext product binaries, the third-party images the stack pulls, and the trademarks involved. This repo ships no AWS credentials, no Graphwise licenses, and no `terraform.tfvars`: you supply your own AWS account, a Route 53-hosted domain, and Graphwise licenses (`poolparty.key`, `graphdb.license`, `uv-license.key` + Maven registry credentials — contact `support@graphwise.ai`). It does ship an n8n workflow seed (`laptop-kit/n8n_db_script_v.1.1.0.sql`) with the baseline GraphRAG chat workflows — its credential rows are empty starting examples for you to fill in, not live secrets.
