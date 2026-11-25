# The appliance on Google Cloud: one Ubuntu VM in its own network, which is cut off from the internet by the VPC
# firewall itself (an egress deny rule), not by anything on the VM. scripts/appliance.sh gcp <step> drives it.
#
# Cost: an e2-medium is about $0.03 an hour plus about $0.005 for its public IP; a run takes about 10 minutes.
# Everything here is deleted by `scripts/appliance.sh gcp destroy` (and by `all`, whatever happens).

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }
}

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "name" {
  type    = string
  default = "vault-appliance"
}

variable "arch" {
  description = "amd64 or arm64: must match the bundle. arm64 needs an Arm machine type such as t2a-standard-2"
  type        = string
  default     = "amd64"
}

variable "machine_type" {
  type    = string
  default = "e2-medium" # 2 shared vCPUs, 4 GB
}

variable "admin_cidrs" {
  description = "Who may reach the VM (ssh, the Kubernetes API, Vault): your public IP, e.g. [\"203.0.113.7/32\"]"
  type        = list(string)
}

variable "ssh_public_key" {
  description = "Public key for the ubuntu user (scripts/appliance.sh makes a throwaway one in .vm/)"
  type        = string
}

provider "google" {
  project = var.project_id
  region  = var.region
  default_labels = {
    purpose = "vault-airgap-test"
    owner   = "vault-k3s-airgap-test"
  }
}

# Its own network, so the firewall rules below apply to this VM only and nothing else in the project is touched
resource "google_compute_network" "appliance" {
  name                    = var.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "appliance" {
  name          = var.name
  network       = google_compute_network.appliance.id
  region        = var.region
  ip_cidr_range = "10.10.0.0/24"
}

# In: ssh (to ship and install), the Kubernetes API and Vault's NodePort (for the tests), from your IP only
resource "google_compute_firewall" "admin_in" {
  name          = "${var.name}-admin-in"
  network       = google_compute_network.appliance.id
  direction     = "INGRESS"
  source_ranges = var.admin_cidrs
  allow {
    protocol = "tcp"
    ports    = ["22", "6443", "30820"]
  }
}

# Out: nothing. This is the air gap. The firewall is stateful, so replies to the connections allowed in still flow,
# and the metadata server (DNS, the ssh key) is always reachable on Google Cloud, whatever the rules say
resource "google_compute_firewall" "deny_all_out" {
  name               = "${var.name}-deny-all-out"
  network            = google_compute_network.appliance.id
  direction          = "EGRESS"
  priority           = 1000 # beats the implied allow-all egress rule (65535)
  destination_ranges = ["0.0.0.0/0"]
  deny {
    protocol = "all"
  }
}

resource "google_compute_instance" "appliance" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2604-lts-${var.arch}"
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.appliance.id
    access_config {} # an ephemeral public IP, so the build machine can reach it; deleted with the VM
  }

  metadata = {
    ssh-keys       = "ubuntu:${var.ssh_public_key}"
    enable-oslogin = "FALSE" # use the key above, not Google accounts
  }

  # no service_account block: the VM gets no Google Cloud identity at all, since it has nothing to call
}

output "external_ip" {
  value = google_compute_instance.appliance.network_interface[0].access_config[0].nat_ip
}
