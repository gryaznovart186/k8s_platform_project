terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.70.0"
    }
  }
  # Store state file in yandex object storage
  backend "s3" {
    endpoint   = "storage.yandexcloud.net"
    bucket     = ""
    key        = ""
    access_key = ""
    secret_key = ""

    skip_region_validation      = true
    skip_credentials_validation = true
  }
}
# Yandex provider settings
provider "yandex" {
  token     = var.ya_api_token
  cloud_id  = var.ya_cloud_id
  folder_id = var.ya_folder_id
  zone      = "ru-central1-a"
}
# Service account for K8S
resource "yandex_iam_service_account" "k8s_cluster_sa" {
  name        = "k8s-cluster"
  description = "Service account to manage k8s"
}

resource "yandex_resourcemanager_folder_iam_member" "k8s_cluster_sa_role" {
  folder_id = var.ya_folder_id
  member    = "serviceAccount:${yandex_iam_service_account.k8s_cluster_sa.id}"
  role      = "editor"
}
# Network for K8S
resource "yandex_vpc_network" "k8s_network" {
  name = "k8s-network"
}
# Route table
resource "yandex_vpc_route_table" "k8s_nodes_route_table" {
  name       = "k9s-nodes-route-table"
  network_id = yandex_vpc_network.k8s_network.id
  static_route {
    destination_prefix = "0.0.0.0/0"
    next_hop_address   = "10.1.1.1"
  }
}
# Public subnet for nat instance
resource "yandex_vpc_subnet" "k8s_subnet_public" {
  name           = "public"
  v4_cidr_blocks = ["10.1.0.0/16"]
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.k8s_network.id
}
# Private subnet for worker node
resource "yandex_vpc_subnet" "k8s_subnet_private" {
  name           = "private"
  v4_cidr_blocks = ["10.2.0.0/16"]
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.k8s_network.id
  route_table_id = yandex_vpc_route_table.k8s_nodes_route_table.id
}
# Nat instance
resource "yandex_compute_instance" "nat_instance" {
  name                      = "k8s-nat"
  zone                      = "ru-central1-a"
  allow_stopping_for_update = true

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      # disk for nat by yandex
      image_id = "fd8drj7lsj7btotd7et5"
    }
  }

  network_interface {
    subnet_id  = yandex_vpc_subnet.k8s_subnet_public.id
    nat        = true
    ip_address = "10.1.1.1"
  }
  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}
# Kuber
resource "yandex_kubernetes_cluster" "k8s_platform" {
  name        = "platform"
  description = "k8s infrastructure platform"

  network_id = yandex_vpc_network.k8s_network.id

  master {
    zonal {
      zone      = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.k8s_subnet_public.id
    }

    version   = "1.21"
    public_ip = true

    maintenance_policy {
      auto_upgrade = false
    }
  }

  service_account_id      = yandex_iam_service_account.k8s_cluster_sa.id
  node_service_account_id = yandex_iam_service_account.k8s_cluster_sa.id
  release_channel         = "STABLE"
}
# Infra nodes
resource "yandex_kubernetes_node_group" "infra_nodes" {
  cluster_id = yandex_kubernetes_cluster.k8s_platform.id
  name       = "infra"

  description = "description"
  version     = "1.21"
  node_labels = {
    "node.kubernetes.io/role" = "infra"
  }
  node_taints = ["node-role=infra:NoSchedule"]


  instance_template {
    platform_id = "standard-v2"
    metadata = {
      ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
    }
    network_interface {
      nat        = false
      subnet_ids = [yandex_vpc_subnet.k8s_subnet_private.id]

    }

    resources {
      memory = 8
      cores  = 4
    }

    boot_disk {
      type = "network-hdd"
      size = 100
    }

    scheduling_policy {
      preemptible = false
    }

    container_runtime {
      type = "containerd"
    }

  }

  scale_policy {
    fixed_scale {
      size = 3
    }
  }

  allocation_policy {
    location {
      zone = "ru-central1-a"
    }
  }

  maintenance_policy {
    auto_upgrade = false
    auto_repair  = false
  }
}
# worker nodes
resource "yandex_kubernetes_node_group" "workers_nodes" {
  cluster_id = yandex_kubernetes_cluster.k8s_platform.id
  name       = "workers"

  description = "description"
  version     = "1.21"

  instance_template {
    platform_id = "standard-v2"
    metadata = {
      ssh-keys = "ubunto:${file("~/.ssh/id_rsa.pub")}"
    }
    network_interface {
      nat        = false
      subnet_ids = [yandex_vpc_subnet.k8s_subnet_private.id]
    }

    resources {
      memory = 8
      cores  = 4
    }

    boot_disk {
      type = "network-hdd"
      size = 100
    }

    scheduling_policy {
      preemptible = false
    }

    container_runtime {
      type = "containerd"
    }

  }

  scale_policy {
    fixed_scale {
      size = 1
    }
  }

  allocation_policy {
    location {
      zone = "ru-central1-a"
    }
  }

  maintenance_policy {
    auto_upgrade = false
    auto_repair  = false
  }
}
