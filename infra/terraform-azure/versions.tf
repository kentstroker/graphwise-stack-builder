# Terraform + provider version pins for the Graphwise Stack AZURE module.
#
# Mirrors infra/terraform-example/versions.tf (the AWS module). Keep the
# ranges conservative and bump them deliberately -- the `azurerm` provider
# had a breaking v3 -> v4 major (subscription_id became mandatory, several
# resources changed default behaviour), so an unplanned upgrade can break
# an otherwise-clean plan.
#
# NOTE: this module still needs the AWS *account* (Route 53 for DNS-01 +
# Bedrock for the LLM), but it deliberately does NOT declare the `aws`
# provider. All AWS access from this stack happens at RUNTIME via static
# access keys handed to the cluster -- never through Terraform. That keeps
# `terraform apply` a single-cloud operation and means the operator's
# laptop does not need AWS credentials to provision the VM.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  # azurerm v4 REQUIRES an explicit subscription_id (v3 inferred it from
  # the CLI context). Set it in terraform.tfvars, or export
  # ARM_SUBSCRIPTION_ID and leave the variable empty.
  subscription_id = var.subscription_id != "" ? var.subscription_id : null

  features {}
}
