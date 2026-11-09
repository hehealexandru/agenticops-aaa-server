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

## Features

- **Ready for GNS3** — runs as a Docker node; the console gives you a shell while FreeRADIUS runs in the background
- **Supervised** — FreeRADIUS is restarted automatically if it crashes; if it keeps crashing, the container
  stops with a failure report instead of pretending to be alive
- **Health check** — Docker `HEALTHCHECK` sends a real RADIUS Status-Server request, not just a process check
- **Maintenance mode** — after a failure the server starts without FreeRADIUS until the administrator has read
  the report and runs `radius-user start`
- **Separate profiles** — `admin` for the network administrator, `agent` for AgenticOps (shorter idle and session timeouts)
- **Hidden passwords** — typed without echo and stored only as SHA-512 crypt hashes
- **No default users** — nobody can log in until the administrator creates a profile
- **Cisco attributes** — `Cisco-AVPair = "shell:priv-lvl=15"`, `Idle-Timeout`, `Session-Timeout`
- **IOS 12.4 compatible** — accepts requests without `Message-Authenticator` (BlastRADIUS-aware for localhost)
- **Configured from environment** — shared secret and allowed router networks set in the GNS3 template
- **Persistent data** — profiles, logs, failure reports and accounting records in `/data`
- **Accounting** — exec start/stop records for every login
- **Profile tool** — `radius-user` to add, test, change, list and delete profiles

## Structure

```
agenticops-aaa-server/
├── Dockerfile
├── .dockerignore
├── README.md
├── bin/
│   ├── aaa-entrypoint     main process: validates the key, renders clients.conf, starts the
│   │                      supervisor, gives the console shell, coordinates shutdown
│   ├── aaa-supervise      runs FreeRADIUS in the foreground and restarts it when it crashes
│   ├── aaa-healthcheck    Docker HEALTHCHECK (RADIUS Status-Server probe)
│   └── radius-user        profile management, status, restart, start
├── lib/
│   └── aaa-common.sh      shared paths and helpers
└── tests/
    └── run.sh             shellcheck + container integration tests
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

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `AAA_RADIUS_KEY` | (required) | Shared secret, min. 16 characters, no spaces, quotes or backslashes |
| `RADIUS_CLIENTS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` | Routers allowed to send requests |
| `AGENT_IDLE_TIMEOUT` | `300` | `Idle-Timeout` (s) for `agent` profiles |
| `AGENT_SESSION_TIMEOUT` | `3600` | `Session-Timeout` (s) for `agent` profiles |
| `AAA_MAX_RESTARTS` | `5` | Automatic restarts tolerated within `AAA_RESTART_WINDOW` |
| `AAA_RESTART_WINDOW` | `60` | Window (s) for counting crashes |

## Requirements

- **Docker Engine** (`docker-ce`) on the Linux host running GNS3, not Docker Desktop. GNS3 adds
  the node's `eth0` through `ubridge` on the host; with Docker Desktop the container runs inside a
  VM, never receives `eth0`, and the GNS3 init script waits forever (empty console).
- GNS3 2.2+

## Build

```bash
docker build -t agenticops-aaa-server:1.1 .
```

Quick test outside GNS3:

```bash
docker run -it --rm -e AAA_RADIUS_KEY=AgenticOpsLabKey2026 agenticops-aaa-server:1.1
radius-user add ai-agent agent
radius-user test ai-agent        # expect Access-Accept
radius-user status               # state, Status-Server probe, last log lines
```

## Add it to GNS3

1. **Edit → Preferences → Docker containers → New**, pick `agenticops-aaa-server:1.1`.
2. Name: `AAA-Server`, adapters: `1`, console type: `telnet`.
3. Environment variables:
   ```
   AAA_RADIUS_KEY=<same value as in AgenticOps .env>
   RADIUS_CLIENTS=10.0.0.0/8
   ```
4. **Advanced → Additional persistent directories:** `/data`
   (profiles, logs, failure reports and accounting records survive node restarts and project exports).
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
   Typing `exit` in the console shell stops the node.

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
radius-user status                   # state, restarts, Status-Server probe, last log lines
radius-user restart                  # checks the configuration first, then restarts FreeRADIUS
```

Every change is checked with `freeradius -C` before FreeRADIUS is restarted; if the check fails,
the running server keeps its previous configuration.

AgenticOps stores the agent profile locally with `login aaa` (hidden input), so the credentials
never pass through the conversation or the LLM.

## Health and supervision

```
tini (PID 1) ── aaa-entrypoint ─┬─ aaa-supervise radius ── freeradius -f
                                └─ console shell (or tail -F without a TTY)
```

- **Crash:** `aaa-supervise` restarts FreeRADIUS with a backoff of 1, 2, 4, 8, 8 s and logs every
  event in `/data/log/supervisor.log` and on the console.
- **Crash loop:** after `AAA_MAX_RESTARTS` restarts within `AAA_RESTART_WINDOW` seconds, the
  supervisor gives up. It writes a failure report to `/data/log/radius-failure-<time>.log`
  (recent errors, configuration check, last lines of both logs), marks the failure in
  `/data/state/radius.failed` and stops the container (exit code 1). The node stops in GNS3,
  so the failure is visible.
- **Health check:** `aaa-healthcheck` sends a Status-Server request to `127.0.0.1:1812`. The result
  is visible in `docker ps` / `docker inspect`; it only reports, it never restarts anything.
- **Stop:** `docker stop` (or stopping the node) shuts FreeRADIUS down cleanly in about a second.

### Recovering from a failure (maintenance mode)

1. Start the node again. Because `/data/state/radius.failed` exists, the server starts in
   **maintenance mode**: the console shows the failure reason and the report path, FreeRADIUS is
   not started and the health check reports `unhealthy`.
2. Read the report and the logs:
   ```bash
   radius-user status
   less /data/log/radius-failure-*.log
   less /data/log/radius.log /data/log/supervisor.log
   ```
   Profiles can still be added, changed or deleted while in maintenance mode.
3. Fix the cause, then start FreeRADIUS:
   ```bash
   radius-user start          # refuses to start while the configuration check fails
   ```

If the configuration check already fails when the container starts (for example a corrupted file
in `/data/users.d`), the server enters maintenance mode directly, without a crash loop.

The same files are also readable from the host, in the GNS3 project directory
(`project-files/docker/<node-id>/data/`), even while the node is stopped.

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

From the Docker host:
```bash
docker ps                       # STATUS shows (healthy) / (unhealthy)
```

On the router:
```
show aaa servers
test aaa group radius ai-agent <password> legacy
```

## Tests

```bash
tests/run.sh                    # shellcheck, docker build, integration tests (about 2 minutes)
SKIP_BUILD=1 IMAGE=agenticops-aaa-server:1.1 tests/run.sh
```

Requires Docker Engine, `shellcheck` and `python3` (to drive the console through a pseudo-terminal,
like GNS3). The tests cover Access-Accept/Reject, the shared secret staying off command lines,
intentional restart, crash recovery, give-up and container stop, maintenance mode and recovery,
a broken configuration at startup, Ctrl-C and `exit` on the console, clean `docker stop` with and
without a TTY, and input validation.

## Security notes

- The container refuses to start without `AAA_RADIUS_KEY` (min. 16 characters, no spaces,
  quotes or backslashes).
- Local tools (`radius-user test`, the health check) read the shared secret from a root-only file
  (`/run/aaa/radius.secret`, mode 600), so it never appears on a command line or in `ps`.
- IOS 12.4 does not send `Message-Authenticator`, so FreeRADIUS logs a BlastRADIUS warning
  the first time each router authenticates. Requests are still accepted; the warning only goes
  away with clients that support it (newer IOS/IOS-XE), where you can set
  `require_message_authenticator = yes`.
- There are no default profiles: nobody can log in until the administrator creates one.
- Authentication attempts are logged in `/data/log/radius.log`, accounting records in
  `/data/radacct`.
- Anyone with access to the node console can manage profiles; protect access to the GNS3
  project accordingly.