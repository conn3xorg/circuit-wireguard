# circuit-wireguard

A Conn3x circuit that joins your hosts into a WireGuard network. Give it a map of hosts and it installs `wireguard-tools`, makes a key pair on each host, writes `/etc/wireguard/wg0.conf` with every other host as a peer, and keeps `wg-quick@wg0` running. Three VPS hosts in different clouds, a homelab box and an offsite backup server can all talk over private `10.77.0.x` addresses, without anyone copying public keys between terminals.

By default every host connects to every other. Name one host as `hub` and the rest connect only through it, which suits hosts behind NAT that can't reach each other directly. Laptops and phones that Conn3x doesn't manage can join as extra peers by public key.

## Usage

```hcl
module "wireguard" {
  source = "github.com/conn3xorg/circuit-wireguard?ref=v0.1.0"

  hosts = {
    web  = "203.0.113.10"
    db   = { address = "203.0.113.11", tunnel_ip = "10.77.0.20" }
    home = { address = "198.51.100.7", endpoint = "" }
  }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  persistent_keepalive = 25

  extra_peers = {
    laptop = { public_key = "JQFo/pDmx0k60jGvYJl7/tUcUqRpUCR2LtO3empPYA0=", tunnel_ip = "10.77.0.100" }
  }
}

output "wireguard_public_keys" {
  value = module.wireguard.public_keys
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.` From `web`, `ping 10.77.0.20` now reaches `db` through the tunnel.

WireGuard listens on UDP port 51820 on every host. This circuit doesn't open it in a firewall. With [circuit-firewall](https://github.com/conn3xorg/circuit-firewall), add `{ port = "51820/udp" }` to its `allow`, and open it in your cloud provider's firewall too.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks a package name by distribution, and Conn3x can't ask a host that doesn't exist yet. Set `os` as well when you put `depends_on` on this module, or the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.node : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on two throwaway containers first, see [examples/local](examples/local).

## Where the keys come from

Each host makes its own private key, with `wg genkey`, in `/etc/wireguard/wg0.key` (mode `0600`). The key never leaves the host: it isn't in a variable, the plan, the state or `wg0.conf`. wg-quick loads it from the file when the tunnel comes up, through `PostUp = wg set %i private-key /etc/wireguard/wg0.key`.

The step that makes the key prints the host's public key. Conn3x keeps a command step's output, and the other hosts' `wg0.conf` files read the public key from there. So what lands in state is the public keys and the config files, which hold public keys, addresses and endpoints. That's also why `wg0.conf` has no `PrivateKey` line.

A host that already has `/etc/wireguard/wg0.key` keeps it, so you can bring an existing WireGuard host under Conn3x, or lose the state, without changing keys.

The key step runs once per host, when the host is added. Conn3x doesn't watch the key file after that. If you rebuild a host at the same address, or replace its key by hand, run the step again so the others learn the new public key:

```sh
conn3x apply -replace='module.wireguard.conn3x_command.wireguard__key["db"]'
```

To rotate a key, delete `/etc/wireguard/wg0.key` on the host first, then run the same command.

## Addresses and endpoints

Every host gets an address in `network`, `10.77.0.0/24` by default. A host object's `tunnel_ip` sets it. Hosts without one are numbered in order of name: with hosts `a`, `b` and `c`, they get `.1`, `.2` and `.3`. The same hosts always get the same addresses, but adding a host whose name sorts before others moves them up one. For a network you'll add to, set `tunnel_ip` on each host. If two hosts or extra peers end up with the same address, the plan fails and says so.

A host's endpoint is where the other hosts send its packets. It's the address Conn3x logs in on, unless the host object sets `endpoint`, which you need when Conn3x reaches the host on a different address from the other hosts, such as a private address, a port forward or a jump host. `endpoint` takes an address or name, which gets `listen_port` added, or a full `host:port`, such as `"vpn.example.com:51821"` or `"[2001:db8::1]:51820"`.

Set `endpoint = ""` for a host the others can't reach, such as one at home behind NAT. It has no endpoint in the others' configs, and it reaches them instead. Set `persistent_keepalive = 25` so it keeps its NAT mapping open, or the others can't reply once the mapping expires.

## Hub and spoke

With `hub = "web"`, the other hosts peer with `web` alone and send it traffic for the whole of `network`. `web` peers with every host and turns on IP forwarding, so spoke-to-spoke traffic passes through it. Extra peers peer with the hub too, and the spokes route to their `allowed_ips` through it.

The hub forwards between its own `wg0` and `wg0`. A firewall on it that drops forwarded traffic, such as firewalld's default policy, has to allow that.

Going from a hub back to a full mesh rewrites each config, but leaves forwarding on at the old hub.

## Extra peers

`extra_peers` adds peers Conn3x doesn't manage, such as a laptop. Make its key pair on the device, pass the public key and an address in `network`, and the hosts accept it: every host in a full mesh, or just the hub. `allowed_ips` adds networks behind it, such as a home LAN.

Its own config is up to you. Use the `public_keys`, `tunnel_ips` and `endpoints` outputs to write a `[Peer]` for each host it should reach, or one for the hub with `AllowedIPs` set to the whole network.

## What it does

On each host, in order:

1. Installs `wireguard-tools`, and `iproute2` or `iproute`, whose `ip` command wg-quick uses. Both come from the distribution's own repositories. The WireGuard kernel module is part of the kernel on every distribution listed below.
2. Makes `/etc/wireguard` with mode `0700`, then the key pair as described in [Where the keys come from](#where-the-keys-come-from).
3. Writes `/etc/wireguard/wg0.conf` with mode `0600`: the host's address, `listen_port`, `mtu` if set, and a `[Peer]` for each peer with its public key, `AllowedIPs`, endpoint and keepalive.
4. Starts `wg-quick@wg0` now and at boot, and restarts it when the file changes. A restart drops the tunnel for about a second. `wg-quick` can reload peers without one, but not a changed address or MTU.

On the hub, it also sets `net.ipv4.ip_forward`, or `net.ipv6.conf.all.forwarding` for an IPv6 `network`, to 1.

Before the circuit runs, the `conn3x_host` data source reads each host's distribution over SSH, which picks the name of the `ip` package.

### What it doesn't do

- It doesn't open UDP `listen_port` in a firewall. See [Usage](#usage).
- It doesn't route anything but the tunnel addresses, extra peers' `allowed_ips` and, on spokes, `network`. There's no option to send all traffic through a host as an exit node.
- It doesn't use preshared keys, set DNS, or manage interfaces other than `wg0`.
- Removing a host from `hosts` drops it from the other hosts' configs, but leaves WireGuard running on the removed host with its last config. Deleting the module leaves every host as it was. Run `systemctl disable --now wg-quick@wg0` on a host to stop it there.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to join, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", tunnel_ip = "10.77.0.5" }`. A host object can set `tunnel_ip`, its address in `network`; `endpoint`, where the other hosts reach it (see [Addresses and endpoints](#addresses-and-endpoints)); `host_key`, `user`, `port`, `private_key_file` and `jump_hosts` for SSH; and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `network` | string | `"10.77.0.0/24"` | Network the tunnel addresses come from. Each host's `wg0` gets its prefix length. |
| `hub` | string | `null` | Name of the host the others connect through. When null, every host connects to every other. |
| `listen_port` | number | `51820` | UDP port WireGuard listens on, on every host. |
| `persistent_keepalive` | number | `0` | Seconds between keepalive packets to each peer, such as `25`. Set it when a host is behind NAT. `0` sends none. |
| `mtu` | number | `null` | MTU of `wg0`. When null, wg-quick works it out from the route to each endpoint. |
| `extra_peers` | map(object) | `{}` | Peers Conn3x doesn't manage, by name. Each takes `public_key` and `tunnel_ip`, and optional `allowed_ips`, a list of networks behind it, and `endpoint`, as `host:port`. |

## Outputs

| Name | Description |
| --- | --- |
| `public_keys` | Each host's WireGuard public key, by host name. |
| `tunnel_ips` | Each host's address in `network`, by host name. |
| `endpoints` | Where each host listens, as `host:port`, by host name. Null for a host with `endpoint = ""`. |

## Requirements

Requires Conn3x v0.6.6 or later and systemd on each host, with a package mirror the host can reach. Every host needs to reach at least one other host, or the hub, on UDP `listen_port`.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to two containers of each on amd64, checks that the second plan has no changes, has each ping the other's tunnel address through `wg0`, checks for a handshake, the extra peer and the file modes, then switches to hub and spoke, plans again with no changes and pings once more. The same checks ran by hand on arm64, the switch to hub and spoke on Debian 13 only.

A three-host hub and spoke ran by hand on Rocky Linux 10 containers, with the third host reached through a jump host and `endpoint = ""`: the two spokes pinged each other through the hub. The two hosts that already had keys kept them under the new state.

Over the internet, an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet, SELinux enforcing, pinged each other over the tunnel with the default settings. After a reboot of the Rocky Linux host, the tunnel came back by itself, the audit log had no denials, and the next plan had no changes.

## License

MPL-2.0. See [LICENSE](LICENSE). WireGuard is a registered trademark of Jason A. Donenfeld; wireguard-tools is GPL-2.0.
