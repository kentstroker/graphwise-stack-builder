# Graphwise Stack -- AZURE infrastructure for a single-node demo deployment.
#
# Creates: one Resource Group, one VNet + subnet, one Network Security
# Group, one NIC, optionally one Static/Standard Public IP, one Linux VM
# (x86_64, memory-optimized), an optional daily auto-shutdown schedule,
# and a cloud-init bootstrap script that preps the OS, installs Docker +
# kind + kubectl + helm, clones the stack repo, and brings up a
# single-node KIND Kubernetes cluster.
#
# This is the Azure twin of infra/terraform-aws/main.tf. It is a
# SEPARATE, self-contained module -- nothing here is shared with the AWS
# module, and changing one never affects the other. From the KIND layer
# upward (all 13 Helm charts, both release orderings, every day-2 script)
# the two paths are identical, which is the whole point of the port.
#
# THREE DELIBERATE DIFFERENCES FROM THE AWS MODULE, all documented at
# length in README.md:
#
#   1. No IAM role. An Azure VM cannot assume an AWS role, so cert-manager's
#      Route 53 DNS-01 solver authenticates with a static, zone-scoped IAM
#      access key instead of the EC2 instance profile + IMDSv2 chain. The
#      whole aws_iam_role / aws_iam_role_policy / aws_iam_instance_profile
#      block from the AWS module is simply absent here.
#
#   2. Explicit VNet + subnet. Azure has no "default VPC" analogue, so the
#      AWS module's data.aws_vpc.default / data.aws_subnets.default lookups
#      become two real resources.
#
#   3. Time-based auto-shutdown, not idle-CPU. `arn:aws:automate:...:ec2:stop`
#      is a free native CloudWatch action with no Azure equivalent.

# ---------------------------------------------------------------------------
# Naming, tags, and derived locals
# ---------------------------------------------------------------------------

locals {
  # Sanitized subdomain for Azure resource names: dots -> hyphens. Lets
  # multi-level subdomains (e.g. "demo.stroker") become "demo-stroker",
  # which several Azure resource types require outright (dots are illegal
  # in NSG / NIC / disk names).
  subdomain_slug = replace(var.subdomain, ".", "-")

  name_tag = "${var.instance_name_prefix}-${var.subdomain}"

  # Explicit, role-suffixed names so each resource is instantly
  # recognisable in the Azure Portal's filter UI.
  rg_name       = var.resource_group_name != "" ? var.resource_group_name : "${var.instance_name_prefix}-${local.subdomain_slug}-rg"
  vnet_name     = "${var.instance_name_prefix}-${local.subdomain_slug}-vnet"
  subnet_name   = "${var.instance_name_prefix}-${local.subdomain_slug}-subnet"
  nsg_name      = "${var.instance_name_prefix}-${local.subdomain_slug}-nsg"
  nic_name      = "${var.instance_name_prefix}-${local.subdomain_slug}-nic"
  pip_name      = "${var.instance_name_prefix}-${local.subdomain_slug}-pip"
  instance_name = "${var.instance_name_prefix}-${local.subdomain_slug}-vm"

  base_tags = {
    Name      = local.name_tag
    Subdomain = var.subdomain
    ManagedBy = "terraform"
    Creator   = var.creator
    Purpose   = var.purpose
    Cloud     = "azure"
  }

  tags = merge(local.base_tags, var.extra_tags)

  hostname_fqdn = "${var.subdomain}.${var.base_domain}"

  # Route 53 credential file for the cert-manager DNS-01 solver. Defaults
  # to route53-credentials.env alongside this module (gitignored by the
  # folder-local .gitignore). Absent -> empty string -> cloud-init skips
  # the write and cluster-bootstrap.sh has no static creds to find, which
  # is a hard failure at cert issuance time. Deliberately NOT fatal at
  # plan time: an operator may want to provision the VM first and drop
  # the credential in by hand afterwards.
  route53_credentials_path = var.route53_credentials_file != "" ? var.route53_credentials_file : "${path.module}/route53-credentials.env"
  route53_credentials_b64  = fileexists(local.route53_credentials_path) ? filebase64(local.route53_credentials_path) : ""
}

# ---------------------------------------------------------------------------
# n8n encryption key
# ---------------------------------------------------------------------------
# Generated once by Terraform (24 bytes of entropy = 48 hex chars,
# equivalent to `openssl rand -hex 24`) and persisted in state. The key
# MUST NOT change after first n8n boot -- n8n encrypts every stored
# credential with it, so rotating it breaks every saved connection.
#
# Empty `keepers` keeps the value stable across re-applies; it only
# regenerates on destroy + apply, which is also when the n8n DB gets
# wiped, so a new key is fine at that point.
resource "random_id" "n8n_encryption_key" {
  byte_length = 24
  keepers     = {}
}

# ---------------------------------------------------------------------------
# cloud-init bootstrap payload
# ---------------------------------------------------------------------------
# gzip = false, unlike the AWS module. AWS caps user_data at 16 KB, which
# forced gzip once the licenses and secrets were inlined as base64. Azure's
# custom_data cap is 64 KB, so this payload (~12 KB) fits uncompressed with
# room to spare -- and an uncompressed multipart is the better-trodden path
# through the Azure Linux Agent -> cloud-init handoff. Keep it that way
# unless the payload actually outgrows the cap.
data "cloudinit_config" "bootstrap" {
  gzip          = false
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    filename     = "bootstrap.sh"
    content = templatefile("${path.module}/user-data.sh.tpl", {
      github_repo_url    = var.github_repo_url
      github_branch      = var.github_branch
      hostname_fqdn      = local.hostname_fqdn
      n8n_encryption_key = random_id.n8n_encryption_key.hex
      route53_zone_id    = var.route53_zone_id
      le_email           = var.le_email
      target_user        = var.admin_username
      kind_version       = var.kind_version
      kubectl_version    = var.kubectl_version
      helm_version       = var.helm_version

      # Static IAM key pair for cert-manager's Route 53 DNS-01 solver.
      # Written to ~/.graphwise-route53.env (mode 600) and sourced by
      # /etc/profile.d/graphwise.sh, which is what puts AWS_ACCESS_KEY_ID
      # into the environment cluster-bootstrap.sh runs in.
      route53_credentials_b64 = local.route53_credentials_b64

      # Operator files that live locally in this folder (gitignored, so they
      # do NOT ride the git clone) -- inlined as base64 and written by
      # cloud-init. Empty string when a file is absent (the write is skipped).
      graphwise_secrets_b64 = fileexists("${path.module}/graphwise-secrets.yaml") ? filebase64("${path.module}/graphwise-secrets.yaml") : ""
      n8n_txt_b64           = fileexists("${path.module}/n8n.txt") ? filebase64("${path.module}/n8n.txt") : ""
      poolparty_key_b64     = fileexists("${path.module}/files/licenses/poolparty.key") ? filebase64("${path.module}/files/licenses/poolparty.key") : ""
      graphdb_license_b64   = fileexists("${path.module}/files/licenses/graphdb.license") ? filebase64("${path.module}/files/licenses/graphdb.license") : ""
      uv_license_key_b64    = fileexists("${path.module}/files/licenses/uv-license.key") ? filebase64("${path.module}/files/licenses/uv-license.key") : ""
    })
  }
}

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------
# Everything Terraform manages for this deployment lives here, so a
# `terraform destroy` is a clean single-group teardown. That is also why
# the long-lived public IP belongs in a DIFFERENT group -- see the
# existing_public_ip_name variable.
resource "azurerm_resource_group" "stack" {
  name     = local.rg_name
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# Network: VNet + subnet
# ---------------------------------------------------------------------------
# Azure has no default VNet, so unlike the AWS module (which deliberately
# rides the account's default VPC to keep scope tight) these have to be
# real resources. 10.42.0.0/16 is chosen to be unlikely to collide with a
# corporate VNet if this is ever peered, and it does not overlap KIND's
# default pod (10.244.0.0/16) or service (10.96.0.0/12) CIDRs -- those are
# internal to the node container, but keeping them distinct avoids a
# confusing debugging session later.
resource "azurerm_virtual_network" "stack" {
  name                = local.vnet_name
  address_space       = ["10.42.0.0/16"]
  location            = azurerm_resource_group.stack.location
  resource_group_name = azurerm_resource_group.stack.name
  tags                = local.tags
}

resource "azurerm_subnet" "stack" {
  name                 = local.subnet_name
  resource_group_name  = azurerm_resource_group.stack.name
  virtual_network_name = azurerm_virtual_network.stack.name
  address_prefixes     = ["10.42.1.0/24"]
}

# ---------------------------------------------------------------------------
# Network Security Group -- the ONLY public-facing ports on the stack
# ---------------------------------------------------------------------------
# Azure NSGs deny all inbound from the internet by default, so only the
# three allow rules are needed -- there is no equivalent of the AWS
# module's explicit egress block (outbound is allowed by default, which
# the stack needs for Docker Hub, Let's Encrypt, GitHub, and Bedrock).
resource "azurerm_network_security_group" "stack" {
  name                = local.nsg_name
  location            = azurerm_resource_group.stack.location
  resource_group_name = azurerm_resource_group.stack.name
  tags                = local.tags

  # SSH restricted to the admin CIDR. Every direct-port service
  # (Keycloak :8080, PoolParty :8081, GraphDB :7200/7201, etc.) is bound
  # to 127.0.0.1 inside the VM, so the only admin path to those raw
  # ports is an SSH tunnel.
  security_rule {
    name                       = "ssh-from-admin"
    description                = "SSH from admin CIDR"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_cidr
    destination_address_prefix = "*"
  }

  # Port 80 (HTTP -> HTTPS redirect) restricted to admin_cidr. Let's
  # Encrypt issuance and renewal do NOT require port 80 -- the
  # ClusterIssuer is DNS-01 via Route 53 exclusively.
  security_rule {
    name                       = "http-from-admin"
    description                = "HTTP (redirects to 443) - admin only"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = var.admin_cidr
    destination_address_prefix = "*"
  }

  # Port 443 restricted to admin_cidr. All app traffic enters here via
  # ingress-nginx.
  security_rule {
    name                       = "https-from-admin"
    description                = "HTTPS (every app) - admin only"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.admin_cidr
    destination_address_prefix = "*"
  }

  # Stop managing rules declaratively after first apply -- the same
  # trade-off the AWS module makes with lifecycle.ignore_changes=[ingress].
  # Operators routinely edit the admin CIDR out-of-band when their home IP
  # changes (that is what scripts/azure-manage-inbound-ip.sh is for);
  # without this, the next apply would revert the edit.
  #
  # CONSEQUENCE, and it is the same lockout trap the AWS path has: changes
  # to admin_cidr in terraform.tfvars stop taking effect after the first
  # apply. Keep terraform.tfvars in sync with reality anyway, because a
  # destroy/apply rebuild DOES read it -- a stale value there re-locks you
  # out of the fresh VM.
  lifecycle {
    ignore_changes = [security_rule]
  }
}

resource "azurerm_subnet_network_security_group_association" "stack" {
  subnet_id                 = azurerm_subnet.stack.id
  network_security_group_id = azurerm_network_security_group.stack.id
}

# ---------------------------------------------------------------------------
# Public IP -- two modes, mirroring the AWS module's EIP handling
# ---------------------------------------------------------------------------
#   - `use_existing` mode (existing_public_ip_name != ""): look the IP up
#     in an operator-owned resource group and only associate it. Terraform
#     never manages the object, so destroy leaves it intact and the Route 53
#     A records stay valid for the next apply.
#   - `fresh` mode (default): allocate a new Static/Standard IP inside this
#     deployment's resource group. Destroy deletes the resource group and
#     therefore the IP, so DNS must be re-pointed after every rebuild.
#
# `use_existing` matters more on Azure than on AWS: destroy here removes an
# entire resource group, so a Terraform-managed IP is guaranteed lost, not
# merely likely.
locals {
  use_existing_pip = var.existing_public_ip_name != ""

  # Single source of truth for the public IP regardless of mode.
  public_ip_id = local.use_existing_pip ? data.azurerm_public_ip.existing[0].id : azurerm_public_ip.stack[0].id
  public_ip    = local.use_existing_pip ? data.azurerm_public_ip.existing[0].ip_address : azurerm_public_ip.stack[0].ip_address
}

data "azurerm_public_ip" "existing" {
  count               = local.use_existing_pip ? 1 : 0
  name                = var.existing_public_ip_name
  resource_group_name = var.existing_public_ip_resource_group_name
}

resource "azurerm_public_ip" "stack" {
  count               = local.use_existing_pip ? 0 : 1
  name                = local.pip_name
  location            = azurerm_resource_group.stack.location
  resource_group_name = azurerm_resource_group.stack.name

  # Static + Standard is the only combination worth using here: Standard
  # SKU IPs are always statically allocated and are the current Azure
  # default going forward (Basic SKU is retired). "Static" guarantees the
  # address survives a deallocate/start cycle -- which matters because
  # deallocate is the normal way to park this stack overnight, and a
  # Dynamic IP would come back with a different address and break DNS.
  allocation_method = "Static"
  sku               = "Standard"

  tags = local.tags
}

# ---------------------------------------------------------------------------
# NIC
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "stack" {
  name                = local.nic_name
  location            = azurerm_resource_group.stack.location
  resource_group_name = azurerm_resource_group.stack.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.stack.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = local.public_ip_id
  }
}

# ---------------------------------------------------------------------------
# Virtual machine
# ---------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "stack" {
  name                = local.instance_name
  computer_name       = local.instance_name
  location            = azurerm_resource_group.stack.location
  resource_group_name = azurerm_resource_group.stack.name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = merge(local.tags, { Name = local.instance_name })

  network_interface_ids = [azurerm_network_interface.stack.id]

  # Password auth off entirely -- the SSH key is the only way in, matching
  # the AWS module's key-pair-only posture.
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  custom_data = data.cloudinit_config.bootstrap.rendered

  os_disk {
    name                 = "${local.instance_name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  # Marketplace images that carry a purchase plan require this block AND a
  # one-time `az vm image terms accept` on the subscription. Toggled by
  # var.image_has_plan because first-party images (Canonical Ubuntu, RedHat
  # PAYG RHEL) reject a plan block outright.
  dynamic "plan" {
    for_each = var.image_has_plan ? [1] : []
    content {
      name      = var.image_sku
      publisher = var.image_publisher
      product   = var.image_offer
    }
  }

  # Managed boot diagnostics (no storage account to manage). Gives you the
  # serial console and boot screenshot in the Portal, which is the only way
  # to debug a VM whose cloud-init wedged before sshd came up -- the Azure
  # equivalent of EC2's "Get system log".
  boot_diagnostics {}

  # Two attributes are intentionally ignored after creation, mirroring the
  # AWS module's reasoning:
  #
  # - custom_data: changes require a full VM rebuild. Treat cloud-init as
  #   fire-once; runtime config changes happen on the VM, not via Terraform.
  #
  # - source_image_reference: with version = "latest", every publisher
  #   image refresh would otherwise mark the VM for force-replace --
  #   destroying the OS disk and every PVC on it -- on the next apply, even
  #   when the intended change was a tag. The AWS module lost a fully
  #   validated demo deployment to exactly this bug with AMIs. To upgrade
  #   deliberately: pin var.image_version to the new version and apply
  #   (which will plan a controlled replace; back up first if you care).
  lifecycle {
    ignore_changes = [custom_data, source_image_reference]
  }
}

# ---------------------------------------------------------------------------
# Auto-shutdown: deallocate the VM daily at a fixed local time
# ---------------------------------------------------------------------------
# NOT a port of the AWS module's idle-CPU CloudWatch alarm. Read
# var.auto_shutdown_enabled's description and README.md -> Auto-shutdown
# before assuming parity: this fires on the clock, not on idleness, so it
# will deallocate a VM that is mid-demo at the configured hour.
#
# It DOES deallocate rather than merely stop, which is the behaviour that
# actually matters for cost -- an Azure VM stopped from inside the guest OS
# keeps billing for compute; only a deallocation releases the hardware.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "stack" {
  count = var.auto_shutdown_enabled ? 1 : 0

  virtual_machine_id = azurerm_linux_virtual_machine.stack.id
  location           = azurerm_resource_group.stack.location
  enabled            = true

  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone

  # notification_settings is a REQUIRED block on this resource, so it is
  # always emitted -- `enabled` is what actually turns the mail on or off.
  #
  # `email` is the empty string rather than null when notifications are off.
  # A null here is the untested path: the provider forwards the block to the
  # DevTest API, which has rejected a disabled block carrying a null email.
  # An empty string is ignored when enabled = false and costs nothing.
  # terraform validate cannot catch either shape -- this is an API-layer
  # constraint -- so do not "simplify" it back to a conditional null.
  notification_settings {
    enabled         = var.auto_shutdown_notification_email != ""
    time_in_minutes = 30
    email           = var.auto_shutdown_notification_email
  }

  tags = local.tags
}
