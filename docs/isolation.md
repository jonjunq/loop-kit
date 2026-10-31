# Isolation and security

The loop runs coding agents unattended for days. They install packages, run servers, execute whatever the tests
need and read whatever the repo pulls in (dependencies, web pages, documentation). Treat the machine they run on as
**disposable and untrusted**.

## Where to run it

Any of these, with a normal (non-root, no sudo) user that owns the project:

| Option | Notes |
|---|---|
| A VM (Proxmox, libvirt, VirtualBox, UTM…) | Strongest isolation. Snapshot it before starting |
| An LXC container (Proxmox, Incus) | Light; unprivileged, with nesting only if your stack needs containers |
| A cloud VM | Easy to throw away; mind the cost of leaving it on for days |
| Docker (`docker/Dockerfile`) | See below. Do not mount your home or the Docker socket into it |

Not recommended: your own laptop or a server with anything you care about.

## Permissions

`PERMS` decides what the agents may do without asking:

- `--permission-mode auto` (default): Claude Code's classifier decides. Safer, but nobody is there to approve what
  it blocks, so a worker can get stuck on something legitimate (installing a package, starting a test server).
- `--dangerously-skip-permissions`: no checks at all. The loop runs smoothly, which is why it is the usual choice,
  but **only inside a sandbox you can throw away**, with the network lockdown below.

## Lock down the network

The agents need the internet (package registries, the Claude API, docs). They do not need your LAN.

- Allow outbound internet and DNS; **drop everything to private ranges** (`10.0.0.0/8`, `172.16.0.0/12`,
  `192.168.0.0/16`, `100.64.0.0/10`, link-local, and your IPv6 ULA), except your DNS resolver if it is local.
- Allow inbound only what you use: SSH from your admin machine, and the roadmap (8090) / demo ports from your LAN.
- The roadmap and the demo have no authentication. To reach them from outside, put them behind a reverse proxy with
  auth (or use an SSH tunnel / a VPN), never a bare port forward.

## Secrets

- Give the sandbox only what the build needs. Prefer mocks and dev mailboxes; the planner marks anything requiring
  real credentials as out of scope or mocked.
- `loopkit.env` is git-ignored, but anything in the sandbox is readable by the agents. A notification token there can
  be read (and used) by them. To keep tokens out, use [the remote watcher](../examples/remote-watch/README.md): the
  sandbox only writes `logs/notify.log` and a trusted machine forwards it.
- Claude Code's own credentials live in the sandbox user's home; use an account (or API key with a spend limit) you
  are comfortable exposing to that sandbox.

## Docker

```bash
git clone https://github.com/jonjunq/loop-kit && cd loop-kit
docker build -f docker/Dockerfile -t loop-kit .                 # PLAYWRIGHT=0 to skip browser dependencies
docker run -d --name myapp --restart unless-stopped \
  -v loopkit-myapp-home:/home/loop -v "$PWD/../myapp:/work" \
  -p 127.0.0.1:8090:8090 -p 127.0.0.1:3000:3000 loop-kit
docker exec -it myapp bash
#   claude                       # log in once (stored in the home volume)
#   loopkit init /work && cd /work && claude --model opus   # plan
#   ./loopkit/tmux.sh && tmux attach -t loop     # loop, roadmap and guard, as in the README
```

Inside, the user is `loop` (no sudo). The image has git, jq, tmux, python3, Node 22, Claude Code and Chromium's
system dependencies for Playwright. Docker's default network still reaches your LAN: add firewall rules on the host
(e.g. `DOCKER-USER` chain) or use a dedicated VM if that matters to you.

## What the harness itself protects

It cannot stop a malicious agent, but it does keep honest mistakes contained: agents never write the plan's state,
their stray changes are reverted, every reset is preceded by a check that nothing uncommitted would be lost, and the
whole history is in git, so you can always go back.
