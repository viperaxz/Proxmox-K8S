provider "proxmox" {}
provider "talos" {}

terraform {
  # Uncomment and configure for remote state with locking
  # backend "s3" {
  #   bucket         = "terraform-state"
  #   key            = "proxmox-k8s/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.89.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.9.0"
    }
  }

  required_version = ">= 1.5.0"
}
