<p align="center">
  <img src="https://raw.githubusercontent.com/hehealexandru/agenticops_network_config_ai_agent/main/agenticops_white.png" alt="AgenticOps Logo" width="2500">
</p>

<h1 align="center">AgenticOps AAA Server – FreeRADIUS for GNS3 Labs</h1>

<p align="center">
  <img src="https://img.shields.io/badge/FreeRADIUS-3.2-red" alt="FreeRADIUS">
  <img src="https://img.shields.io/badge/Debian-Trixie-A81D33?logo=debian&logoColor=white" alt="Debian">
  <img src="https://img.shields.io/badge/Docker-Container-2496ED?logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/GNS3-Supported-00a98f?logo=cisco&logoColor=white" alt="GNS3">
  <img src="https://img.shields.io/badge/Cisco-IOS%2012.4%20%7C%2015.x-1BA0D7?logo=cisco&logoColor=white" alt="Cisco IOS">
  <img src="https://img.shields.io/badge/RADIUS-UDP%201812%2F1813-orange" alt="RADIUS">
  <img src="https://img.shields.io/badge/TACACS%2B-Planned-lightgrey" alt="TACACS+">
  <img src="https://img.shields.io/badge/AgenticOps-Compatible-purple" alt="AgenticOps">
</p>

A FreeRADIUS server packaged as a Docker image for GNS3 labs, built to work with
[AgenticOps](https://github.com/hehealexandru/agenticops_network_config_ai_agent). Cisco routers
(c3725, c7200) authenticate SSH logins against it; the network administrator and the AgenticOps
agent each get their own profile.

## Features

- **Ready for GNS3** — runs as a Docker node; the console gives you a shell while FreeRADIUS runs in the background
- **Separate profiles** — `admin` for the network administrator, `agent` for AgenticOps (shorter idle and session timeouts)
- **Hidden passwords** — typed without echo and stored only as SHA-512 crypt hashes
- **No default users** — nobody can log in until the administrator creates a profile
- **Cisco attributes** — `Cisco-AVPair = "shell:priv-lvl=15"`, `Idle-Timeout`, `Session-Timeout`
- **IOS 12.4 compatible** — accepts requests without `Message-Authenticator` (BlastRADIUS-aware for localhost)
- **Configured from environment** — shared secret and allowed router networks set in the GNS3 template
- **Persistent data** — profiles, logs and accounting records in `/data`
- **Accounting** — exec start/stop records for every login
- **Profile tool** — `radius-user` to add, test, change, list and delete profiles

## Structure

```
agenticops-aaa-server/
├── Dockerfile
├── .dockerignore
├── README.md
└── bin/
    ├── aaa-entrypoint     startup: validates the key, renders clients.conf, starts FreeRADIUS
    └── radius-user        profile management
```

## Contract with AgenticOps

| Item | Value |
|---|---|
| Shared secret | `AAA_RADIUS_KEY`, same value in this container and in the AgenticOps `.env` |
| Ports | UDP 1812 (authentication), UDP 1813 (accounting) |
| Allowed clients | `RADIUS_CLIENTS`, comma-separated IPs or CIDRs of the routers (default: all private ranges) |
| Roles | `admin`: priv-lvl 15. `agent`: priv-lvl 15, `Idle-Timeout` 300 s, `Session-Timeout` 3600 s |

IOS 12.4 defaults to the legacy RADIUS ports 1645/1646, so routers must be configured with
`auth-port 1812 acct-port 1813`.

## Requirements

- **Docker Engine** (`docker-ce`) on the Linux host running GNS3, not Docker Desktop. GNS3 adds
  the node's `eth0` through `ubridge` on the host; with Docker Desktop the container runs inside a
  VM, never receives `eth0`, and the GNS3 init script waits forever (empty console).
- GNS3 2.2+

## Build

```bash
docker build -t agenticops-aaa-server:1.0 .
```

Quick test outside GNS3:

```bash
docker run -it --rm -e AAA_RADIUS_KEY=AgenticOpsLabKey2026 agenticops-aaa-server:1.0
radius-user add ai-agent agent
radius-user test ai-agent        # expect Access-Accept
```

## Add it to GNS3

1. **Edit → Preferences → Docker containers → New**, pick `agenticops-aaa-server:1.0`.
2. Name: `AAA-Server`, adapters: `1`, console type: `telnet`.
3. Environment variables:
   ```
   AAA_RADIUS_KEY=<same value as in AgenticOps .env>
   RADIUS_CLIENTS=10.0.0.0/8
   ```
4. **Advanced → Additional persistent directories:** `/data`
   (profiles, logs and accounting records survive node restarts and project exports).
5. Drag the node into the topology, connect it to a router or switch, then
   **right-click → Edit config** and set a static IP for `eth0`, e.g.:
   ```
   auto eth0
   iface eth0 inet static
       address 10.0.100.10
       netmask 255.255.255.0
       gateway 10.0.100.1
   ```
6. Start the node and open its console: you get a shell, FreeRADIUS runs in the background.

## Manage profiles (network administrator)

Profiles are created manually, from the node console. Passwords are typed hidden and stored
only as SHA-512 crypt hashes in `/data/users.d`.

```bash
radius-user add netadmin admin       # human administrator
radius-user add ai-agent agent       # AgenticOps agent
radius-user list
radius-user test ai-agent            # Access-Accept means the profile works
radius-user passwd ai-agent
radius-user del ai-agent
radius-user status                   # process state + last log lines
```

AgenticOps will store the agent profile through a `login` command with hidden input (in progress),
so the credentials never pass through the conversation or the LLM.

## Router configuration (reference)

Automatic configuration from AgenticOps is in progress; until then, apply it manually (IOS 12.4):

```
username console-admin privilege 15 secret <local-console-password>
aaa new-model
radius-server host 10.0.100.10 auth-port 1812 acct-port 1813 key <AAA_RADIUS_KEY>
ip radius source-interface FastEthernet0/0
aaa authentication login VTY group radius
aaa authorization exec VTY group radius
aaa authentication login CONSOLE local
aaa accounting exec default start-stop group radius
line vty 0 4
 login authentication VTY
 authorization exec VTY
line con 0
 login authentication CONSOLE
```

- SSH (VTY) uses **only** RADIUS: if the server is down, nobody logs in over SSH until an
  administrator starts it again.
- The console uses a **local** user known only to the administrator, as the recovery path.
- The source interface IP must be inside `RADIUS_CLIENTS`, otherwise the server silently
  ignores the requests.

## Verify

On the server console:
```bash
radius-user status
tail -f /data/log/radius.log
```

On the router:
```
show aaa servers
test aaa group radius ai-agent <password> legacy
```

## Security notes

- The container refuses to start without `AAA_RADIUS_KEY` (min. 16 characters, no spaces,
  quotes or backslashes).
- IOS 12.4 does not send `Message-Authenticator`, so FreeRADIUS logs a BlastRADIUS warning
  the first time each router authenticates. Requests are still accepted; the warning only goes
  away with clients that support it (newer IOS/IOS-XE), where you can set
  `require_message_authenticator = yes`.
- There are no default profiles: nobody can log in until the administrator creates one.
- Authentication attempts are logged in `/data/log/radius.log`, accounting records in
  `/data/radacct`.
- Anyone with access to the node console can manage profiles; protect access to the GNS3
  project accordingly.
