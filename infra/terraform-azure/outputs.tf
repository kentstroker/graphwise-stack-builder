# Outputs -- printed after `terraform apply` completes.
#
# Cover the things an operator acts on immediately after provisioning:
#   1. The public IP (so they add the two Route 53 A records)
#   2. The exact AWS CLI command that creates those records
#   3. SSH commands
#   4. The image-version pin command (protects the VM from force-replace)
#   5. Power commands -- and the deallocate-vs-stop billing warning
#   6. The expected final public URLs

output "public_ip" {
  description = "Public IPv4 of the VM. Add this as the value for both Route 53 A records (see route53_dns_records). When existing_public_ip_name is set this stays stable across rebuilds -- DNS is set-and-forget. When unset, a fresh IP is allocated each apply and DNS must be updated after every rebuild."
  value       = local.public_ip
}

output "public_ip_mode" {
  description = "Which public-IP mode is active: 'existing' (operator-owned, survives destroy, set-and-forget DNS) or 'fresh' (created in this deployment's resource group and DELETED with it on destroy)."
  value       = local.use_existing_pip ? "existing (${var.existing_public_ip_name} in rg ${var.existing_public_ip_resource_group_name})" : "fresh (created this apply -- destroy will delete it and invalidate DNS)"
}

output "route53_dns_records" {
  description = "Single AWS CLI command to UPSERT the two A records in the Route 53 hosted zone. Idempotent (UPSERT) -- safe to re-run after the IP changes. Requires the operator's laptop AWS profile to have route53:ChangeResourceRecordSets on the zone. Yes, this is an AWS command on an Azure deployment: DNS deliberately stays in Route 53 (see README.md -> Why Route 53 stays)."
  value       = <<-EOT
    Run this once on your laptop to set / refresh the two A records:

      aws route53 change-resource-record-sets --hosted-zone-id ${var.route53_zone_id} --change-batch '{
        "Changes":[
          {"Action":"UPSERT","ResourceRecordSet":{"Name":"${var.subdomain}.${var.base_domain}","Type":"A","TTL":300,"ResourceRecords":[{"Value":"${local.public_ip}"}]}},
          {"Action":"UPSERT","ResourceRecordSet":{"Name":"*.${var.subdomain}.${var.base_domain}","Type":"A","TTL":300,"ResourceRecords":[{"Value":"${local.public_ip}"}]}}
        ]
      }'

    Verify with:
      dig +short ${var.subdomain}.${var.base_domain}
      dig +short poolparty.${var.subdomain}.${var.base_domain}

    Both should return ${local.public_ip} (Route 53 propagation is near-instant).
  EOT
}

output "resource_group" {
  description = "Resource group holding every resource in this deployment. `terraform destroy` -- or `az group delete --name <this>` -- removes all of it. If public_ip_mode says 'fresh', that includes the public IP."
  value       = azurerm_resource_group.stack.name
}

output "vm_id" {
  description = "Full ARM resource ID of the VM. Every `az vm ...` command in this module's scripts accepts it via --ids, which avoids having to pass name + resource group separately."
  value       = azurerm_linux_virtual_machine.stack.id
}

output "image_pin_command" {
  description = "Run this after the first successful apply, then paste the result into terraform.tfvars as image_version. Marketplace 'latest' resolves to a concrete version at deploy time; pinning it makes `terraform plan` output honest about what would replace the VM. (Belt-and-braces: azurerm_linux_virtual_machine.stack also carries lifecycle.ignore_changes on source_image_reference, so an unpinned deployment is still protected once provisioned -- the pin is for plan clarity, and for making an intentional image upgrade a deliberate one-line edit.)"
  value       = "az vm show --ids ${azurerm_linux_virtual_machine.stack.id} --query storageProfile.imageReference.exactVersion -o tsv"
}

output "image_reference_requested" {
  description = "The marketplace image triple this module asked Azure for. If apply failed with an image-not-found error, THIS is what to check first -- the shipped defaults are unverified best guesses (see variables.tf). Confirm with: az vm image list --publisher <publisher> --all -o table"
  value       = "${var.image_publisher}:${var.image_offer}:${var.image_sku}:${var.image_version}"
}

output "graphwise_env_exports" {
  description = "Ready-to-paste shell exports for the GRAPHWISE_KEY/HOST/USER env vars that every doc command and laptop-side script relies on (ssh / scp / push-config.sh / pull-config.sh). Paste into your terminal once per session, or append to your shell rc. GRAPHWISE_KEY points at the PRIVATE half of ssh_public_key_path."
  value       = <<-EOT
    # Paste these into your terminal (or append to ~/.zshrc / ~/.bashrc):
    export GRAPHWISE_KEY=${replace(var.ssh_public_key_path, ".pub", "")}
    export GRAPHWISE_HOST=${var.subdomain}.${var.base_domain}
    export GRAPHWISE_USER=${var.admin_username}

    # If DNS hasn't propagated yet, use the IP instead:
    #   export GRAPHWISE_HOST=${local.public_ip}
  EOT
}

output "ssh" {
  description = "SSH command for the VM. The admin account is named ec2-user by default even on Azure -- deliberate, so that /home/ec2-user hardcodes in infra/kind/kind-config.yaml and the chart templates need no edits (see variables.tf -> admin_username). Uses GRAPHWISE_KEY / GRAPHWISE_HOST / GRAPHWISE_USER from the graphwise_env_exports output."
  value       = "ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST   # GRAPHWISE_HOST=${local.public_ip} or ${var.subdomain}.${var.base_domain}"
}

output "power_commands" {
  description = "How to park and resume this stack. READ THE DEALLOCATE WARNING -- this is the single most expensive difference between the Azure and AWS paths. On AWS, `aws ec2 stop-instances` stops the compute meter. On Azure, a VM merely STOPPED (including `sudo shutdown` from inside the guest, or `az vm stop`) stays in the 'Stopped' state and KEEPS BILLING for compute; only 'Stopped (deallocated)' releases the hardware and stops the meter."
  value       = <<-EOT
    Park the stack (stops the compute meter):
      1. ssh in and quiesce workloads:  ~/gsb/scripts/cluster-stop.sh
      2. az vm deallocate --ids ${azurerm_linux_virtual_machine.stack.id}
         (or: ./scripts/azure-vm-power.sh deallocate)

    Resume:
      1. az vm start --ids ${azurerm_linux_virtual_machine.stack.id}
         (or: ./scripts/azure-vm-power.sh start)
      2. The graphwise-cluster-resume.service systemd unit restarts the KIND
         containers and calls cluster-start.sh automatically -- no manual step.
         Watch it with: systemctl status graphwise-cluster-resume

    DO NOT use `az vm stop` or `sudo shutdown` to park the stack. Both leave
    the VM in 'Stopped' (not 'Stopped (deallocated)') and you keep paying full
    compute price for an idle box. Check which state you are in with:
      az vm get-instance-view --ids ${azurerm_linux_virtual_machine.stack.id} \
        --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
  EOT
}

output "expected_urls" {
  description = "Where each app lands once DNS + LE certs are in place. Identical to the AWS path -- everything from the KIND layer up is the same charts and the same ingress hostnames. The observability triplet (dashboard / prometheus / grafana) is provisioned by scripts/cluster-bootstrap.sh."
  value = {
    chatbot          = "https://graphrag.${var.subdomain}.${var.base_domain}/"
    poolparty        = "https://poolparty.${var.subdomain}.${var.base_domain}/PoolParty/"
    keycloak         = "https://auth.${var.subdomain}.${var.base_domain}/"
    graphdb          = "https://graphdb.${var.subdomain}.${var.base_domain}/"
    graphdb_projects = "https://graphdb-projects.${var.subdomain}.${var.base_domain}/"
    n8n_workflows    = "https://graphrag.${var.subdomain}.${var.base_domain}/workflows/"
    dashboard        = "https://dashboard.${var.subdomain}.${var.base_domain}/"
    prometheus       = "https://prometheus.${var.subdomain}.${var.base_domain}/"
    grafana          = "https://grafana.${var.subdomain}.${var.base_domain}/"
  }
}

output "route53_credentials_status" {
  description = "Whether the static IAM key pair for cert-manager's Route 53 DNS-01 solver was found and inlined into cloud-init. If this says MISSING, the wildcard certificate will never issue and every OIDC-dependent app (PoolParty, GraphRAG conversation) will fail at startup -- see README.md -> Route 53 credentials."
  value       = local.route53_credentials_b64 != "" ? "OK -- inlined from ${local.route53_credentials_path} (written to ~/.graphwise-route53.env on the VM, mode 600)" : "MISSING -- no file at ${local.route53_credentials_path}. cert-manager will have no AWS credentials and the wildcard cert will NOT issue. Create the file with AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION lines and re-apply, or write ~/.graphwise-route53.env on the VM by hand."
}

output "bootstrap_log_hint" {
  description = "Path on the VM where cloud-init writes its bootstrap log. The KIND cluster bring-up runs inside that script. Tail it on first SSH to confirm the install finished cleanly -- the last line is 'Bootstrap complete', which is the marker scripts/deploy-stack.sh gates on before it will run."
  value       = "ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST 'sudo tail -f /var/log/bootstrap.log'   # GRAPHWISE_HOST=${local.public_ip} or your subdomain"
}

output "WAIT_before_ssh" {
  description = "cloud-init configures the login shell (kubeconfig, aliases, Docker group membership) during first boot. SSHing in before it completes lands you in an unconfigured shell where kubectl/kind won't work, and scripts/deploy-stack.sh will refuse to run until it sees the 'Bootstrap complete' marker."
  value       = "*** Wait at least 10 minutes before running deploy-stack.sh -- cloud-init is still installing Docker/KIND and building the cluster. Watch progress with: ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST 'sudo tail -f /var/log/bootstrap.log' ***"
}
