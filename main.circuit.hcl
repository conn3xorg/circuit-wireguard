# Facts give each host's distribution, which names the package with the ip
# command wg-quick needs. Cloud images have it; minimal ones may not.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os      = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  iproute = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "iproute2" : "iproute" }

  # Hosts without a tunnel_ip take the next address in network by name, so
  # the same hosts always get the same addresses.
  names     = sort(keys(var.hosts))
  prefix    = split("/", var.network)[1]
  tunnel_ip = { for i, name in local.names : name => coalesce(try(var.hosts[name].tunnel_ip, null), cidrhost(var.network, i + 1)) }

  # A host's endpoint is where the others send its packets: the endpoint it
  # names, else the address Conn3x logs in on. An empty endpoint leaves it
  # out, for a host the others can't reach, which then has to reach them.
  endpoint = {
    for name, h in var.hosts : name => (
      try(h.endpoint, null) == null ? try(h.address, h) : h.endpoint
    )
  }
  endpoint_port = {
    for name, e in local.endpoint : name => (
      e == "" ? null :
      can(regex("^(\\[[0-9a-fA-F:.]+\\]|[^:\\[\\]]+):[0-9]+$", e)) ? e :
      strcontains(e, ":") ? "[${e}]:${var.listen_port}" : "${e}:${var.listen_port}"
    )
  }

  key_file = "/etc/wireguard/wg0.key"

  # The public key each host printed when its private key was made. The
  # private key never leaves the host.
  public_key = { for name in local.names : name => trimspace(nonsensitive(conn3x_command.wireguard__key[name].stdout)) }

  extra = {
    for name, p in var.extra_peers : name => {
      public_key  = p.public_key
      allowed_ips = concat(["${p.tunnel_ip}/${strcontains(p.tunnel_ip, ":") ? 128 : 32}"], p.allowed_ips)
      endpoint    = p.endpoint
    }
  }

  host_peer = {
    for name in local.names : name => {
      public_key  = local.public_key[name]
      allowed_ips = ["${local.tunnel_ip[name]}/${strcontains(local.tunnel_ip[name], ":") ? 128 : 32}"]
      endpoint    = local.endpoint_port[name]
    }
  }

  # Full mesh: every host peers with every other host and every extra peer.
  # Hub and spoke: the hub peers with everyone, and a spoke peers with the
  # hub alone, sending it traffic for the whole network and the extra
  # peers' networks.
  peers = {
    for me in local.names : me => (
      var.hub == null || me == var.hub ? merge(
        { for name, p in local.host_peer : name => p if name != me },
        local.extra,
        ) : {
        (var.hub) = merge(local.host_peer[var.hub], {
          allowed_ips = distinct(concat([var.network], flatten([for p in var.extra_peers : p.allowed_ips])))
        })
      }
    )
  }

  config = {
    for me in local.names : me => "${join("\n\n", concat(
      [join("\n", compact([
        "# Written by Conn3x. Changes here are overwritten on the next apply.",
        "[Interface]",
        "Address = ${local.tunnel_ip[me]}/${local.prefix}",
        "ListenPort = ${var.listen_port}",
        var.mtu == null ? "" : "MTU = ${var.mtu}",
        # The private key stays in its own file, so this one, which Conn3x
        # keeps in state, holds nothing secret.
        "PostUp = wg set %i private-key ${local.key_file}",
      ]))],
      [
        for name, p in local.peers[me] : join("\n", compact([
          "# ${name}",
          "[Peer]",
          "PublicKey = ${p.public_key}",
          "AllowedIPs = ${join(", ", p.allowed_ips)}",
          p.endpoint == null ? "" : "Endpoint = ${p.endpoint}",
          var.persistent_keepalive == 0 ? "" : "PersistentKeepalive = ${var.persistent_keepalive}",
        ]))
      ],
    ))}\n"
  }
}

circuit "wireguard" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "tools" {
    package {
      name = "wireguard-tools"
    }
  }

  step "iproute" {
    package {
      name = local.iproute[each.key]
    }
  }

  step "dir" {
    directory {
      path = "/etc/wireguard"
      mode = "0700"
    }
  }

  # Makes the host's private key unless it has one, and prints the public
  # key, which the other hosts' configs read from this step's stdout. With
  # no guard it runs once per host; replacing the step reads the key again.
  step "key" {
    command {
      command = "umask 077 && { test -s ${local.key_file} || wg genkey > ${local.key_file}; } && wg pubkey < ${local.key_file}"
    }
  }

  step "config" {
    file {
      path    = "/etc/wireguard/wg0.conf"
      content = local.config[each.key]
      mode    = "0600"
    }
    notify = [handler.restart]
  }

  step "running" {
    service {
      name    = "wg-quick@wg0"
      state   = "started"
      enabled = true
    }
  }

  # wg-quick's reload can't change the address or MTU, so a changed
  # config restarts the tunnel, which drops it for a moment.
  handler "restart" {
    service {
      name = "wg-quick@wg0"
    }
  }
}

# The hub passes traffic between spokes.
circuit "wireguard_hub" {
  hosts = var.hub == null ? {} : { (var.hub) = var.hosts[var.hub] }

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "forwarding" {
    for_each = strcontains(var.network, ":") ? ["net.ipv6.conf.all.forwarding"] : ["net.ipv4.ip_forward"]
    sysctl {
      name  = item.value
      value = "1"
    }
  }
}
