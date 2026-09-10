# Private Valheim server with Docker

Deploy a password-protected, unlisted Steam Valheim server on an x86-64 Linux machine. This first stage includes Compose, persistent world storage, rotating operational logs, and backups. The stats API is a future extension described below; this repository does not yet run an API.

## Hardware

| Resource | Starting point |
| --- | --- |
| RAM | **8 GB recommended; 4 GB minimum** for a small vanilla server with little else running |
| CPU | 4 fast cores recommended; 2 cores minimum |
| Storage | Budget at least 30 GB SSD initially; increase for growing worlds and backups |
| Architecture | x86-64 / amd64; use an x86 VPS, not an ARM instance |

The RAM/CPU figures come from the [container maintainers](https://github.com/community-valheim-tools/valheim-server-docker#system-requirements). Storage is a planning allowance. For mods, extensive builds, or a colocated website/database, budget **12–16 GB RAM** initially and measure actual load; that is an estimate, not a guaranteed player capacity. This Compose file does not impose a memory limit. Leave memory for Linux and other services.

## 1. Install Docker on Linux

Commands below target a fresh **Ubuntu 24.04 LTS amd64** machine and your existing public IPv4 address. Run the system installation commands from a root shell. For another distribution, follow its [Docker Engine installation guide](https://docs.docker.com/engine/install/), then use the same Compose steps. If Docker is already installed, check `docker compose version` and skip installation.

Install from [Docker's Ubuntu apt repository](https://docs.docker.com/engine/install/ubuntu/):

```bash
apt update
apt install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker compose version
```

If the machine has conflicting Docker/containerd packages already installed, resolve those using Docker's guide before installing these packages. To run Docker as your regular account, add that account to the `docker` group from the root shell, then sign out and back in so the new group membership takes effect:

```bash
usermod -aG docker your-user
```

Membership in the `docker` group grants host-level administrative access. Only grant it to trusted accounts.

## 2. Copy and configure this project

On the Linux server, create the deployment directory from the root shell, replacing `your-user` with the regular account that will manage the server:

```bash
mkdir -p /opt/valheim
chown your-user:your-user /opt/valheim
```

From your local project directory, copy the deployment files (replace the SSH user and IP):

```bash
scp docker-compose.yml .env.example README.md upgrade.sh your-user@YOUR_PUBLIC_IP:/opt/valheim/
```

Back on the Linux server:

```bash
cd /opt/valheim
cp .env.example .env
chmod 600 .env
chmod +x upgrade.sh
nano .env
mkdir -p data/config data/server backups
chmod 700 data backups
docker compose config --quiet
```

### Environment files

| File | Purpose | Commit to Git? |
| --- | --- | --- |
| `.env.example` | Shared configuration template with a placeholder password; copy to `.env` before deployment | Yes |
| `.env` | Actual settings and password for this deployment; used by the commands in this README | No; ignored |
| `.env.production` (optional) | Separate production settings; copy the template and supply `--env-file .env.production` explicitly on each Compose command | No; ignored |

Use `.env` for the standard single-server deployment. If you choose `.env.production`, protect it with `chmod 600 .env.production` and use commands such as `docker compose --env-file .env.production up -d`. That filename is not selected automatically, and selecting another environment file does not create an isolated server or separate world storage.

### Configurable environment variables

These are the variables wired into `docker-compose.yml` and provided in `.env.example`:

| Variable | Default / template value | Required change | Purpose |
| --- | --- | --- | --- |
| `SERVER_NAME` | `Private Valheim` | Optional | Display name of the server |
| `WORLD_NAME` | `Dedicated` | Optional for a new world; match the save name when importing | Selects the world to load or create |
| `SERVER_PASS` | Template placeholder; no Compose fallback | **Yes** | Join password; use a unique value of at least five characters |
| `SERVER_ARGS` | `-modifier resources muchmore -modifier combat veryhard` | Optional | Applies 2x resource drops and the highest combat difficulty |
| `TZ` | `Asia/Manila` | Optional | Time zone for container schedules and local timestamps |
| `VALHEIM_IMAGE` | `ghcr.io/community-valheim-tools/valheim-server:latest` | Optional | Container image reference; can be set to a tested image digest |

Compose rejects an unset or empty `SERVER_PASS`, but does not reject the template placeholder or validate its length. Replace it before starting. Keep the surrounding single quotes if the password contains `$` or `#`. Do not include the password in the server name. Keep `.env` private; Docker administrators can inspect container environment variables.

`SERVER_ARGS` uses Valheim's built-in world modifiers and does not require mods on the server or clients. `resources muchmore` is the 2x resource setting, while `combat veryhard` is the maximum combat difficulty. These settings affect the selected world and are reapplied whenever the server starts. Set `SERVER_ARGS=''` to use normal modifiers. Stop the server cleanly before changing the value, then recreate it with `docker compose up -d`.

### Settings defined directly in Compose

The following values are fixed in the service's `environment` section. Edit `docker-compose.yml` to change them; adding them to `.env` alone will not override these values.

| Variable | Configured value | Purpose |
| --- | --- | --- |
| `SERVER_PUBLIC` | `false` | Keeps the server off the public list |
| `CROSSPLAY` | `false` | Uses Steam networking; see the crossplay notes below before enabling |
| `UPDATE_CRON` | Empty string | Disables scheduled game update checks; startup can still update |
| `RESTART_CRON` | Empty string | Disables scheduled restarts |
| `BACKUPS` | `true` | Enables world backups |
| `BACKUPS_CRON` | `5 * * * *` | Runs backups hourly at minute 5 in the configured time zone |
| `BACKUPS_MAX_AGE` | `7` | Retains scheduled backups for seven days |
| `BACKUPS_DIRECTORY` | `/config/backups` | Container backup path, mounted at `data/config/backups` on the host |
| `STATUS_HTTP` | `false` | Disables the built-in HTTP status service |
| `SUPERVISOR_HTTP` | `false` | Disables the HTTP process-management service |

Set `WORLD_NAME` once and keep it stable: changing it selects another world. To migrate an existing world, stop the server and copy its complete save into `data/config/worlds_local/`. Preserve the whole world directory for directory-based saves, or both matching `.db` and `.fwl` files for older saves. Use the matching world name.

## 3. Allow game traffic

Configure your hosting provider's firewall/security group:

| Inbound traffic | Source |
| --- | --- |
| TCP 22 (or your SSH port) | Your administrative IP |
| UDP 2456–2457 | Players' public IPs, or all IPv4 addresses if their IPs change |

Allow outbound internet access for downloads and Steam services. If behind a router, forward UDP 2456–2457 to this Linux machine's LAN IP. A public IP must actually route to the host; a DNS record alone cannot bypass NAT.

If using UFW, allow your actual SSH port before enabling it:

```bash
ufw allow OpenSSH
ufw allow 2456:2457/udp
ufw enable
ufw status
```

**Docker-published ports can bypass UFW rules.** Enforce source-IP restrictions at the provider firewall or configure Docker-aware forwarding rules; do not rely on a UFW deny rule to hide published ports. See [Docker's firewall documentation](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

“Private” here means password-protected and absent from the public server list, not isolated from the internet. For strict network privacy, use a VPN or a provider firewall allowlist. Do not expose Docker's daemon or management ports.

## 4. Attach your Cloudflare domain

In Cloudflare, select your active domain → **DNS → Records → Add record**:

| Field | Value |
| --- | --- |
| Type | `A` |
| Name | `valheim` |
| IPv4 address | Your existing public IPv4 address |
| Proxy status | **DNS only (gray cloud)** |
| TTL | Auto |

Replace `example.com` throughout with your domain. Ensure the registrar uses the nameservers assigned by Cloudflare. Remove conflicting records for `valheim`; do not add an AAAA record unless you have configured and tested IPv6 connectivity.

The game address is **`valheim.example.com:2456`**. It is not a website URL and needs no HTTPS certificate. Cloudflare's ordinary orange-cloud proxy handles web traffic, so keep this UDP game record DNS-only. This also means the game IP is public and gameplay does not receive Cloudflare's HTTP protection. See [Cloudflare proxy status](https://developers.cloudflare.com/dns/proxy-status/).

Verify resolution:

```bash
getent ahostsv4 valheim.example.com
```

The result should be your server IP. Allow time for cached DNS answers to expire after changes.

### Production layout: Nginx, SSL, and port 8888

Use Nginx with HTTPS for the future stats API. Valheim clients cannot connect through a normal HTTP/HTTPS reverse proxy: gameplay uses UDP. Both services can share your Linux machine and public IP with separate hostnames and ports.

| Service | Public address | Traffic path | Cloudflare DNS record |
| --- | --- | --- | --- |
| Valheim game | `valheim.example.com:2456` | UDP 2456–2457 → Valheim container | `A` record pointing to your IP, **DNS only** |
| Future stats API | `https://api.example.com` | HTTPS TCP 443 → Nginx → HTTP API on port 8888 | `A` record pointing to your IP, **Proxied** |

Players enter `valheim.example.com:2456` in the game, without an `https://` prefix. Keep the existing Valheim port mapping:

```yaml
ports:
  - "2456-2457:2456-2457/udp"
```

Publishing `8888:8888` defaults to TCP and does not make Valheim an HTTP service or move its listening ports. SSL certificates on Nginx secure the API's HTTPS connection; they do not add SSL to Valheim gameplay.

When implementing the API, if Nginx runs directly on the Linux host, add this mapping to the **API service**, not the Valheim service:

```yaml
ports:
  - "127.0.0.1:8888:8888"
```

The API application must listen on `0.0.0.0:8888` inside its container. The mapping makes it reachable through the host's loopback address, allowing Nginx to forward requests without publicly publishing the API port. Configure Nginx's HTTPS virtual host for `api.example.com` to proxy to `http://127.0.0.1:8888`.

If Nginx also runs in Docker, put Nginx and the API on a shared Docker network and proxy to `http://api:8888`, where `api` is the API service name. No host port mapping for the API is needed in that layout; `127.0.0.1` inside the Nginx container refers to Nginx's own container.

For the future HTTPS deployment:

1. Install and configure Nginx with an HTTPS virtual host for `api.example.com` and a certificate covering that hostname. Use a publicly trusted certificate if direct browser access to the origin is needed, or a Cloudflare Origin CA certificate for access through Cloudflare.
2. Add the proxied `api` DNS record shown above and set Cloudflare SSL/TLS mode to **Full (strict)** so the origin connection is also encrypted and its certificate validated.
3. Allow inbound TCP 443 at the provider and host firewalls. Allow TCP 80 if using HTTP-to-HTTPS redirects or an HTTP certificate-validation flow. Keep the database and API backend port private.
4. Configure certificate renewal as appropriate for the certificate issuer, validate the Nginx configuration with `nginx -t`, then reload Nginx and test an implemented API endpoint over HTTPS.

These are deployment instructions for the future API; the current Compose file contains only the game server. See [Cloudflare proxy behavior](https://developers.cloudflare.com/dns/proxy-status/) for the distinction between proxied and DNS-only hostnames.

Nginx can optionally forward game traffic using its separate [UDP `stream` proxy module](https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html). That requires UDP listeners and forwarding for the game ports, does not add HTTPS to gameplay, and still requires a DNS-only game hostname with the ordinary Cloudflare setup. Direct UDP publishing is the simpler layout for this deployment.

## 5. Start and join

```bash
cd /opt/valheim
docker compose pull
docker compose up -d
docker compose logs --follow --tail=100 valheim
```

First startup downloads the game server and can take several minutes. Ctrl+C exits the log viewer without stopping the server. Check logs for successful startup and errors; a running container alone does not prove that the game is ready.

In Valheim choose **Join Game → Add server / Join IP**, enter `valheim.example.com:2456`, then enter the password. Test from outside the server's LAN. If hostname joining fails, try `YOUR_PUBLIC_IP:2456` to separate DNS problems from networking problems. The server intentionally will not appear in the public list. Consult the [official dedicated-server guide](https://valheim.com/support/a-guide-to-dedicated-servers/) for client and administration details.

This configuration uses Steam networking. For non-Steam clients, review the [container's crossplay instructions](https://github.com/community-valheim-tools/valheim-server-docker#crossplay): enable `CROSSPLAY`, publish/allow UDP 2458 as required by the container, recreate the service, and use the crossplay joining flow. Validate that separately before inviting console players.

Useful operations:

```bash
docker compose ps
docker stats --no-stream
free -h
du -sh data/*
docker compose stop       # Graceful shutdown with up to two minutes to save
docker compose up -d      # Start again; startup may update the game
```

The restart policy starts the service after a host reboot unless you explicitly stopped it. After editing `.env` or Compose, run `docker compose up -d`; `restart` alone does not apply configuration changes.

## 6. Backups and restore

| Host path | Contents |
| --- | --- |
| `data/config` | World saves and server configuration |
| `data/config/backups` | Hourly world backups, retained for seven days |
| `data/server` | Downloaded game binaries |
| `backups` | Manual archives made by the steps below |

Bind mounts preserve these files when a container is recreated. Do not delete `data/`. Scheduled backups capture saved state; take a stopped-server backup before an upgrade for a consistent recovery point. Copy backups to another machine or storage service, since same-disk backups cannot survive disk loss. Monitor disk space and prune manual archives yourself.

Create a manual backup on the server:

```bash
cd /opt/valheim
docker compose stop valheim
backup_file="backups/config-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
tar -czf "$backup_file" -C data config
tar -tzf "$backup_file" >/dev/null
docker compose up -d
```

If archiving or verification fails, fix that before upgrading. Save `.env` and Compose separately in secure storage, too.

To restore a manual archive, replace the example filename with an actual backup. This replaces the current world with the archived state and loses progress since that backup:

```bash
cd /opt/valheim
docker compose stop valheim
tar -tzf backups/config-TIMESTAMP.tar.gz
mv data/config "data/config-before-restore-$(date -u +%Y%m%dT%H%M%SZ)"
tar -xzf backups/config-TIMESTAMP.tar.gz -C data
docker compose up -d
docker compose logs --tail=100 valheim
```

The commands above restore our tar archives, not the container's scheduled ZIP backups. For a scheduled backup, inspect and extract it into a temporary directory while stopped, then replace the matching world under `data/config/worlds_local/`, preserving a copy of the previous world first. Test joining and verify world progress after any restore.

## 7. Upgrade Valheim and the container

There are two independent updates: the Docker image supplies the runtime, while Steam supplies the game binaries. This configuration disables scheduled updates and restarts for planned maintenance; **starting the container still checks/installs game updates**. A host reboot can therefore update the game. See the [container update documentation](https://github.com/community-valheim-tools/valheim-server-docker#updates).

For a planned upgrade, notify players and have them disconnect. Then run the upgrade script from the project directory:

```bash
cd /opt/valheim
./upgrade.sh
docker compose logs --follow --tail=100 valheim
```

The script takes the Compose project down, pulls the latest Valheim image, creates and verifies a timestamped `backups/pre-upgrade-*.tar.gz` archive of `data/config`, and starts the service again. If pulling or backing up fails, it attempts to start the service again and exits with an error.

Update clients as well, join the server, and verify the expected world loaded. Merely pulling an image does not update the running container. To check for a game update without changing the image, follow the same backup procedure and recreate the container without the pull step.

For unattended game checks, change `UPDATE_CRON` to `"*/15 * * * *"` and add `UPDATE_IF_IDLE: "true"`, then apply with `up -d`. On unlisted servers, idle detection is heuristic; use planned maintenance if interruption must be avoided. This does not automatically pull newer Docker images.

For reproducible runtime deployments, set `VALHEIM_IMAGE` to a tested `ghcr.io/community-valheim-tools/valheim-server@sha256:...` digest. A pinned image **does not pin the Steam game version**. Rolling back a container alone cannot undo a game update, and older game versions may not read upgraded worlds. Preserve pre-upgrade saves; game rollback requires compatible binaries and clients as well.

## 8. Player logs and a future stats API

Current operational logs are bounded to approximately 100 MB per container. They rotate and are removed when that container is removed/recreated, so they are **not a historical player database**. Export a snapshot before upgrades if useful:

```bash
cd /opt/valheim
docker compose logs --no-color --timestamps valheim > "backups/server-$(date -u +%Y%m%dT%H%M%SZ).log"
```

Suggested next implementation:

1. Forward logs continuously to a persistent collector. The container supports remote syslog and log-event hooks. Keep the collector on an internal Docker network, with no public ingestion port. UDP syslog can lose events; record gaps and avoid presenting it as an audit trail.
2. Parse actual logs from your installed game version into a database. Store UTC timestamps, event type, source identity when present, and a deduplication key. Validate connection, character-spawn, and disconnection patterns against real sessions; a spawn line is not necessarily a new account login. Treat sessions interrupted by crashes or missing logs as incomplete.
3. Expose read-only endpoints such as `/api/server`, `/api/players`, and `/api/sessions`. Suggested metrics are observed joins, last seen, estimated session duration, daily active players, server restarts, and save/backup events. Mark current player counts stale if collection stops. Deaths, kills, inventory, and progression need separately validated telemetry or a compatible mod; do not promise these from vanilla logs.
4. Serve the API behind HTTPS at `api.example.com` through a reverse proxy. That HTTP hostname can use Cloudflare's orange cloud with Full (strict) TLS and a valid origin certificate. Keep the database and collector private, redact IPs/platform IDs from public responses, and never put private API credentials in browser code. Apply authentication to private endpoints and permit only your site's origin where browser CORS is needed.

The container's built-in status HTTP endpoint requires a publicly listed server, so it is disabled here. Its Supervisor API controls processes and should not be exposed as your website API. Use the [container's logging and status documentation](https://github.com/community-valheim-tools/valheim-server-docker#log-filters) when building the collector.

## Troubleshooting

- **Cannot connect:** confirm DNS-only resolution, UDP rules at the provider/router, matching client/server versions, and startup logs. An HTTP request or TCP port test cannot verify the UDP game service.
- **Unexpected empty world:** check `WORLD_NAME`, the mounted save location, and permission errors before playing further. Stop the service before moving saves.
- **Crashes or lag:** inspect `docker stats --no-stream`, `free -h`, disk usage, and `journalctl -k` for out-of-memory kills. Increase resources based on measurements.
- **Version mismatch after an update:** wait for the download/startup to finish, update clients, and inspect logs for Steam download failures.
