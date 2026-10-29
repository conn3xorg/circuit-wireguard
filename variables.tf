variable "hosts" {
  type        = any
  description = "Hosts to join, by name: a map of names to addresses, or to host objects with an address and optional tunnel_ip, endpoint, host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }

  validation {
    condition     = alltrue([for h in var.hosts : try(h.tunnel_ip, null) == null || can(cidrhost("${h.tunnel_ip}/${strcontains(h.tunnel_ip, ":") ? 128 : 32}", 0))])
    error_message = "A host object's tunnel_ip must be an IP address such as \"10.77.0.1\", without a prefix length."
  }

  validation {
    condition     = alltrue([for h in var.hosts : try(h.endpoint, null) == null || can(regex("^[^\\s,]*$", h.endpoint))])
    error_message = "A host object's endpoint is an address or name, optionally with :port, such as \"203.0.113.10\" or \"vpn.example.com:51821\"."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}
variable "network" {
  type        = string
  default     = "10.77.0.0/24"
  description = "Network the tunnel addresses come from, such as \"10.77.0.0/24\". Hosts without a tunnel_ip are numbered from it in order of name."

  validation {
    condition     = can(cidrhost(var.network, 1))
    error_message = "network must be a CIDR block such as \"10.77.0.0/24\"."
  }
}

variable "hub" {
  type        = string
  default     = null
  description = "Name of the host the others connect through. When null, every host connects to every other."

  validation {
    condition     = var.hub == null || contains(keys(var.hosts), coalesce(var.hub, "-"))
    error_message = "hub must be the name of one of the hosts."
  }
}

variable "listen_port" {
  type        = number
  default     = 51820
  description = "UDP port WireGuard listens on, on every host."

  validation {
    condition     = var.listen_port >= 1 && var.listen_port <= 65535 && floor(var.listen_port) == var.listen_port
    error_message = "listen_port must be a port number from 1 to 65535."
  }
}

variable "persistent_keepalive" {
  type        = number
  default     = 0
  description = "Seconds between keepalive packets to each peer, such as 25, which keeps a NAT mapping open for a host behind one. 0 sends none."

  validation {
    condition     = var.persistent_keepalive >= 0 && var.persistent_keepalive <= 65535 && floor(var.persistent_keepalive) == var.persistent_keepalive
    error_message = "persistent_keepalive must be a whole number of seconds from 0 to 65535."
  }
}

variable "mtu" {
  type        = number
  default     = null
  description = "MTU of the wg0 interface. When null, wg-quick works it out from the route to each endpoint."

  validation {
    condition     = var.mtu == null || (coalesce(var.mtu, 1280) >= 576 && coalesce(var.mtu, 1280) <= 9000)
    error_message = "mtu must be from 576 to 9000."
  }
}

variable "extra_peers" {
  type = map(object({
    public_key  = string
    tunnel_ip   = string
    allowed_ips = optional(list(string), [])
    endpoint    = optional(string)
  }))
  default     = {}
  description = "Peers Conn3x doesn't manage, such as laptops and phones, by name. Each has its own public key and tunnel_ip, and optionally networks behind it in allowed_ips and an endpoint. They peer with every host, or with the hub alone."

  validation {
    condition     = alltrue([for p in values(var.extra_peers) : can(regex("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$", p.public_key))])
    error_message = "Each extra peer's public_key must be a WireGuard public key: 44 characters of base64, as wg pubkey prints."
  }

  validation {
    condition     = alltrue([for p in values(var.extra_peers) : can(cidrhost("${p.tunnel_ip}/${strcontains(p.tunnel_ip, ":") ? 128 : 32}", 0))])
    error_message = "Each extra peer's tunnel_ip must be an IP address such as \"10.77.0.100\"."
  }

  validation {
    condition     = alltrue([for p in values(var.extra_peers) : alltrue([for n in p.allowed_ips : can(cidrhost(n, 0))])])
    error_message = "Each extra peer's allowed_ips must be CIDR blocks such as \"192.168.1.0/24\"."
  }

  validation {
    condition     = alltrue([for name in keys(var.extra_peers) : can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", name))])
    error_message = "Extra peer names may use letters, digits, ., - and _."
  }
}
