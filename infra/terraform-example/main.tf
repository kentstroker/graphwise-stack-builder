# Graphwise Stack — AWS infrastructure for a single-node demo deployment.
#
# Creates: one Security Group, one EC2 instance (Debian 13 ARM64 on
# r6g-family Graviton), one Elastic IP associated to the instance, and
# a cloud-init bootstrap script that preps the OS, installs podman +
# kind + kubectl + helm, creates the named user, clones the stack repo,
# and brings up a single-node KIND Kubernetes cluster.
#
# Uses the default VPC + default subnet in the chosen region. This is
# deliberate — a presales demo doesn't need a custom VPC, and keeping
# the module scope tight lets each teammate `terraform apply` in their
# own AWS account without having to reason about networking layout.

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

# Default VPC in the chosen region. Every AWS account has one unless it's
# been explicitly deleted; if yours has been, this module won't work
# without adjustment (either re-create the default VPC or point this at
# an existing custom VPC by swapping the data source for a hardcoded ID).
data "aws_vpc" "default" {
  default = true
}

data "aws_region" "current" {}

# Pick the default-VPC subnet in the specified AZ.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = [var.availability_zone]
  }
}

# Latest official Amazon Linux 2023 ARM64 AMI, via the AWS-maintained SSM
# public parameter for the kernel-DEFAULT line. This always resolves to the
# current default AL2023 ARM64 image; the parameter's `.value` IS the ami-... ID.
#
# Why not `data "aws_ami"` + most_recent: the name glob `al2023-ami-*-arm64`
# also matches the `ecs-` (ECS-optimized) and `minimal-` variants, and whichever
# AWS published most recently wins -- so most_recent could (and did) resolve to
# the ECS AMI rather than the standard image. The SSM kernel-default pointer is
# unambiguous and is exactly what AWS treats as "the latest AL2023".
#
# Migrated from Debian 13 in late 2026 after teammates hit consistent
# "ssh fails immediately after scp" failures on Debian 13. The same SSH+scp
# pattern works cleanly on AL2023 -- root cause appears to be a Debian 13
# kernel/network-stack interaction with AWS Nitro that AL2023 doesn't trigger.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# n8n encryption key for the graphrag-workflows pod. Generated once
# by Terraform (48 hex chars = 24 bytes of entropy, equivalent to
# `openssl rand -hex 24`) and persisted in state. The key MUST NOT
# change after first n8n boot -- n8n encrypts every stored credential
# with it, so rotating breaks every saved connection.
#
# Empty `keepers` block keeps the value stable across re-applies; it
# only regenerates if you `terraform destroy` and re-`apply` (which
# is also when the n8n DB gets wiped, so the new key is fine).
resource "random_id" "n8n_encryption_key" {
  byte_length = 24
  keepers     = {}
}

# Render the user-data cloud-init script with the per-deployment variables
# inlined as template substitutions. hostname_fqdn is the full
# <subdomain>.<base_domain> — surfaced to NEXT_STEPS.txt and used by the
# teammate when they later run prep-scripts/cluster-bootstrap.sh.
data "cloudinit_config" "bootstrap" {
  # gzip: cloud-init auto-detects the gzip magic bytes and decompresses on boot.
  # Required headroom -- inlining graphwise-secrets.yaml + n8n.txt + licenses as
  # base64 pushes the raw multipart past AWS's 16KB user_data cap; gzip brings
  # the payload back to ~10KB with room to spare.
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    filename     = "bootstrap.sh"
    content = templatefile("${path.module}/user-data.sh.tpl", {
      github_repo_url    = var.github_repo_url
      github_branch      = var.github_branch
      hostname_fqdn      = "${var.subdomain}.${var.base_domain}"
      n8n_encryption_key = random_id.n8n_encryption_key.hex
      route53_zone_id    = var.route53_zone_id
      aws_region         = var.region
      le_email           = var.le_email

      # The operator's real graphwise-secrets.yaml -- the single source of truth
      # for all deployment secrets. Loaded dynamically from this folder
      # (gitignored, so it never rides the git clone) and written verbatim by
      # user-data. Empty string when absent, in which case user-data falls back
      # to a fill-in-the-blanks placeholder carrying the generated encryption key.
      graphwise_secrets_b64 = fileexists("${path.module}/graphwise-secrets.yaml") ? filebase64("${path.module}/graphwise-secrets.yaml") : ""

      # Operator files that live locally in this folder (gitignored, so they do
      # NOT ride the git clone) -- inlined as base64 and written by user-data,
      # the same "terraform apply writes it" method as graphwise-secrets.yaml.
      # Empty string when a file is absent (the write is then skipped).
      n8n_txt_b64         = fileexists("${path.module}/n8n.txt") ? filebase64("${path.module}/n8n.txt") : ""
      poolparty_key_b64   = fileexists("${path.module}/files/licenses/poolparty.key") ? filebase64("${path.module}/files/licenses/poolparty.key") : ""
      graphdb_license_b64 = fileexists("${path.module}/files/licenses/graphdb.license") ? filebase64("${path.module}/files/licenses/graphdb.license") : ""
      uv_license_key_b64  = fileexists("${path.module}/files/licenses/uv-license.key") ? filebase64("${path.module}/files/licenses/uv-license.key") : ""
    })
  }
}

# ---------------------------------------------------------------------------
# IAM role + instance profile for the EC2 instance
# ---------------------------------------------------------------------------
# Why: cert-manager (running in the cluster) needs to write
# _acme-challenge TXT records into the Route 53 hosted zone for DNS-01
# wildcard cert issuance. The cert-manager pod talks to AWS via the
# instance metadata service (IMDSv2), which transparently surfaces
# whatever role is attached to the EC2 -- so the chain is:
#
#   cert-manager pod -> AWS SDK -> IMDSv2 -> EC2 instance role -> Route 53
#
# No AWS access key Secret needs to live in the cluster. The role's
# Route 53 policy is scoped to ChangeResourceRecordSets +
# ListResourceRecordSets on a single hostedzone ARN (var.route53_zone_id),
# so even if the role were exfiltrated it could only edit DNS for this
# one zone.
#
# Plus route53:GetChange on `*` because LE polls the change-status API
# after each TXT write and that API isn't zone-scoped.

resource "aws_iam_role" "ec2" {
  name = "${local.instance_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "ec2_route53" {
  name = "graphwise-cert-manager-route53"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.instance_name}-profile"
  role = aws_iam_role.ec2.name

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

locals {
  name_tag = "${var.instance_name_prefix}-${var.subdomain}"

  # Sanitized subdomain for AWS resource names: dots → hyphens. Lets
  # multi-level subdomains (e.g. "demo.stroker") become "demo-stroker"
  # in resource names, which reads cleaner in the AWS Console and
  # avoids the few dashboards that get fussy about dotted names.
  subdomain_slug = replace(var.subdomain, ".", "-")

  # Explicit, role-suffixed names so each resource is instantly
  # recognisable in the AWS Console search/filter UI rather than
  # showing up as launch-wizard-N or relying on the Name tag alone.
  sg_name       = "${var.instance_name_prefix}-${local.subdomain_slug}-sg"
  instance_name = "${var.instance_name_prefix}-${local.subdomain_slug}-ec2"
  eip_name      = "${var.instance_name_prefix}-${local.subdomain_slug}-eip"

  base_tags = {
    Name      = local.name_tag
    Subdomain = var.subdomain
    ManagedBy = "terraform"
    Creator   = var.creator
    Purpose   = var.purpose
  }

  tags = merge(local.base_tags, var.extra_tags)
}

# ---------------------------------------------------------------------------
# Security group — the ONLY public-facing ports on the stack
# ---------------------------------------------------------------------------

resource "aws_security_group" "stack" {
  # Explicit, dot-free name so the SG is easy to spot in the EC2 Console
  # filter (e.g. "graphwise-stack-demo-stroker-sg" rather than the
  # auto-assigned launch-wizard-N).
  name        = local.sg_name
  description = "Graphwise Stack KIND demo - HTTPS only + SSH-from-admin (${var.subdomain})"
  vpc_id      = data.aws_vpc.default.id
  tags = merge(local.tags, {
    Name = local.sg_name
  })

  # SSH is restricted to the admin CIDR. Every direct-port service
  # (Keycloak :8080, PoolParty :8081, GraphDB :7200/7201, etc.) is
  # bound to 127.0.0.1 inside the instance, so the only admin path
  # to those raw ports is an SSH tunnel.
  ingress {
    description = "SSH from admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Port 80 (HTTP → HTTPS redirect) restricted to admin_cidr.
  # Let's Encrypt cert issuance and renewal do NOT require port 80 — the
  # ClusterIssuer uses DNS-01 via Route 53 exclusively (see cluster-bootstrap.sh).
  # Port 80 is kept for the HTTP → HTTPS redirect convenience; locking it to
  # admin_cidr ensures no unauthenticated HTTP traffic reaches the instance.
  ingress {
    description = "HTTP (redirects to 443) - admin only"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Port 443 restricted to admin_cidr.
  # All app traffic enters here via ingress-nginx. Every direct raw port
  # (Keycloak :8080, PoolParty :8081, GraphDB :7200, etc.) stays bound to
  # 127.0.0.1 inside the instance — SSH tunnel is the only path to those.
  # LE cert issuance and renewal are unaffected (DNS-01, no inbound port needed).
  ingress {
    description = "HTTPS (every app) - admin only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Unrestricted outbound — the instance needs to reach Docker Hub for
  # image pulls, Let's Encrypt for cert issuance, and GitHub for the
  # repo clone. Narrowing outbound hasn't been worth the maintenance
  # cost for a demo stack.
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Stop managing ingress declaratively after first apply. Operators
  # routinely add a second port-22 rule manually (via the AWS Console)
  # to allow EC2 Instance Connect from AWS's service prefix list -- see
  # SETUP.md §9 for the Console walkthrough. With inline `ingress` blocks
  # alone, Terraform would treat that manual rule as drift and delete
  # it on the next apply.
  #
  # Trade-off: changes to the SSH/HTTP/HTTPS ingress blocks above also
  # stop taking effect post-provision. Existing stacks must update the
  # port 80/443 rules manually via the AWS Console (change source to
  # admin_cidr). New stacks pick up the correct rules on first apply.
  lifecycle {
    ignore_changes = [ingress]
  }
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------

resource "aws_instance" "stack" {
  # nonsensitive(): SSM parameter values are always flagged sensitive, but this
  # public parameter just returns a public ami-... ID. Strip the flag here so it
  # doesn't propagate to aws_instance.stack.ami or the ami_id output.
  ami                    = var.ami_override != "" ? var.ami_override : nonsensitive(data.aws_ssm_parameter.al2023_arm64.value)
  instance_type          = var.instance_type
  key_name               = var.key_pair_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.stack.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  user_data_base64       = data.cloudinit_config.bootstrap.rendered
  tags = merge(local.tags, {
    Name = local.instance_name
  })

  # IMDSv2 required — closes the SSRF-to-credentials hole that IMDSv1
  # leaves open. Modern AWS SDKs speak v2 by default.
  #
  # http_put_response_hop_limit = 3 (not the AWS default of 1, not the
  # K8s-on-EC2 typical of 2): cert-manager runs as a pod inside a
  # KIND node container which itself runs on the EC2 host. IMDS
  # response packets must traverse two network namespaces to reach
  # the pod (pod -> KIND node container -> host), so the IP TTL
  # needs to survive both hops. With limit=2 the response TTL hits
  # zero at the second hop and IMDS appears unreachable -- error
  # surfaces as "no EC2 IMDS role found" in the cert-manager Route 53
  # solver, blocking DNS-01 wildcard cert issuance forever.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 3
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
    tags = merge(local.tags, {
      Name = "${local.instance_name}-root"
    })
  }

  # Two attributes are intentionally ignored after creation:
  #
  # - user_data_base64: changes require tainting + re-apply, which means
  #   a full instance rebuild. Treat user-data as fire-once: any runtime
  #   config changes happen on-instance, not via Terraform.
  #
  # - ami: data.aws_ssm_parameter.al2023_arm64 resolves the current default
  #   AL2023 AMI. Without ignore_changes, every AWS-published AL2023 AMI refresh
  #   (which happens constantly) would mark the instance for force-replace --
  #   destroying the root EBS volume and every PVC on it -- on the next
  #   `terraform apply`, even when the user's intended change was tiny
  #   (SG, tags, etc.). We've lost a fully-validated demo deployment to
  #   this exact bug. Belt-and-braces with var.ami_override (which lets
  #   you also pin the ami at the lookup site so plan output is clean).
  #   To intentionally upgrade the AMI: bump var.ami_override to the new
  #   ami-... ID and apply (will plan a controlled replace).
  lifecycle {
    ignore_changes = [user_data_base64, ami]
  }
}

# ---------------------------------------------------------------------------
# Elastic IP — two modes:
#   - `use_existing` mode (existing_eip_allocation_id != ""): look up a
#     pre-allocated EIP by allocation ID and associate it with this
#     instance. Terraform does NOT manage the EIP itself, so destroy
#     leaves it intact and the GoDaddy DNS records stay valid for the
#     next apply. The teammate owns the EIP lifecycle outside Terraform.
#   - `fresh` mode (default): allocate a brand-new EIP each apply. The
#     EIP is destroyed on `terraform destroy`, so DNS must be re-pointed
#     after every rebuild. Simpler, no AWS-side prep, but tedious.
# ---------------------------------------------------------------------------

locals {
  use_existing_eip = var.existing_eip_allocation_id != ""

  # Single source of truth for the public IP, regardless of mode.
  # Outputs and downstream interpolations read this so they don't need
  # to know which path produced it.
  public_ip = local.use_existing_eip ? data.aws_eip.existing[0].public_ip : aws_eip.stack[0].public_ip
}

# Look up the pre-allocated EIP when in use_existing mode. Skipped
# entirely otherwise — `count = 0` keeps the data source out of the plan.
data "aws_eip" "existing" {
  count = local.use_existing_eip ? 1 : 0
  id    = var.existing_eip_allocation_id
}

# Fresh-mode EIP. Created+destroyed alongside the instance.
resource "aws_eip" "stack" {
  count    = local.use_existing_eip ? 0 : 1
  domain   = "vpc"
  instance = aws_instance.stack.id
  tags = merge(local.tags, {
    Name = local.eip_name
  })

  depends_on = [aws_instance.stack]
}

# Use_existing-mode association. Pre-allocated EIP is referenced by
# allocation ID; Terraform creates only the association, so a destroy
# detaches the EIP without releasing it.
resource "aws_eip_association" "existing" {
  count         = local.use_existing_eip ? 1 : 0
  instance_id   = aws_instance.stack.id
  allocation_id = var.existing_eip_allocation_id
}

# ---------------------------------------------------------------------------
# Auto-shutdown: stop the instance after 1 hour of idle CPU
# ---------------------------------------------------------------------------
# CloudWatch native ec2:stop action — no Lambda, no EventBridge, no extra IAM.
# 12 × 5-minute periods = 1 continuous hour at or below the threshold before
# the stop fires. A single spike (helm upgrade, PoolParty reindex, etc.) resets
# the clock, so an actively-used instance won't be stopped mid-session.
# treat_missing_data = notBreaching: a monitoring gap doesn't trigger a stop.
# Disable by setting auto_shutdown_enabled = false in terraform.tfvars.
resource "aws_cloudwatch_metric_alarm" "cpu_idle_shutdown" {
  count = var.auto_shutdown_enabled ? 1 : 0

  alarm_name          = "${local.instance_name}-cpu-idle-shutdown"
  alarm_description   = "Stop instance after 1 h CPU <= ${var.auto_shutdown_cpu_threshold}% (idle cost guard)"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 12
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 3600
  statistic           = "Average"
  threshold           = var.auto_shutdown_cpu_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.stack.id
  }

  alarm_actions = ["arn:aws:automate:${data.aws_region.current.name}:ec2:stop"]

  tags = local.tags
}
