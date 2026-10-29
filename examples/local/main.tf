# up.sh writes these to up.auto.tfvars: the first SSH port, and each
# container's address on Podman's network.
variable "port" {
  type    = number
  default = 2222
}

variable "a_ip" {
  type = string
}

variable "b_ip" {
  type = string
}

variable "hub" {
  type    = string
  default = null
}

module "wireguard" {
  source = "../.."

  # Conn3x logs in through Podman's port forwards on 127.0.0.1, so each
  # host names the address the other reaches it on.
  hosts = {
    a = { address = "127.0.0.1", port = var.port, endpoint = var.a_ip }
    b = { address = "127.0.0.1", port = var.port + 1, endpoint = var.b_ip }
  }
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  hub                  = var.hub
  persistent_keepalive = 25
  mtu                  = 1380

  # A laptop that isn't running. Its private key was thrown away.
  extra_peers = {
    laptop = { public_key = "JQFo/pDmx0k60jGvYJl7/tUcUqRpUCR2LtO3empPYA0=", tunnel_ip = "10.77.0.100" }
  }
}

output "public_keys" {
  value = module.wireguard.public_keys
}

output "tunnel_ips" {
  value = module.wireguard.tunnel_ips
}
