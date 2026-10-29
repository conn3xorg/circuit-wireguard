# Local example

Applies circuit-wireguard to two throwaway Rocky Linux 10 containers with systemd, `a` and `b`, and has them ping each other through the tunnel. You need Conn3x and Podman.

wg-quick creates a network interface, so the containers run privileged, which is simplest with rootful Podman. A container can't load kernel modules, so the machine Podman runs on needs the `wireguard` module loaded first. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
podman machine ssh sudo modprobe wireguard                # macOS
sudo modprobe wireguard                                   # Linux
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To look at the result:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 'wg show; ping -c 3 10.77.0.2'
```

Minimal images have no `ping`; install `iputils` (`iputils-ping` on Debian and Ubuntu) first.

Conn3x logs in through port forwards on `127.0.0.1`, which the containers can't use to reach each other. So `up.sh` writes each container's address on Podman's network to `up.auto.tfvars`, and `main.tf` passes it as the host's `endpoint`. The example also adds a laptop as an extra peer, which doesn't exist, and sets a keepalive and an MTU.

To try hub and spoke, with `a` as the hub:

```sh
conn3x apply -var hub=a
```

`up.sh` listens on `127.0.0.1:2222` for `a` and `2223` for `b`. Set `PORT` to use another pair, and `NAME` to change the containers' names from `circuit-wireguard-a` and `-b`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the containers, their volumes, the key and the state.
