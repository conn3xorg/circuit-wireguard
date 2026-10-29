output "public_keys" {
  description = "Each host's WireGuard public key, by host name."
  value       = local.public_key
}

output "tunnel_ips" {
  description = "Each host's address inside the tunnel, by host name."
  value       = local.tunnel_ip

  precondition {
    condition     = length(distinct(concat(values(local.tunnel_ip), [for p in var.extra_peers : p.tunnel_ip]))) == length(var.hosts) + length(var.extra_peers)
    error_message = "Two hosts or extra peers have the same tunnel address. A tunnel_ip you set may be one another host was numbered with; set tunnel_ip on that host too."
  }
}

output "endpoints" {
  description = "Where each host listens, as host:port, by host name. Null for a host with an empty endpoint."
  value       = local.endpoint_port
}
