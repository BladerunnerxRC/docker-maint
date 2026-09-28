# docker-maint

Docker host maintenance: volume backup/restore scripts plus a colorized CLI toolkit for
administering, monitoring, documenting and generating compose stacks.

## Backup / restore

| File | Purpose |
|---|---|
| `backup.sh` | Docker volume backup script. Deploy it as a Portainer stack that creates a temporary container on a cron schedule. The container exits with code 0 and removes itself. |
| `restore.sh` | Restores Docker volumes, then redeploys each stack and waits for its health URL. |
| `docker_full_backup.yml` | Compose stack that runs `backup.sh` in a temporary container with the NAS volume mounted. |
| `restic/` | Backrest and Stack-Back web GUIs for restic (see `restic/README.md`). |

## CLI toolkit (`bin/`)

A set of Bash tools that share `lib/common.sh`, which provides the colors, tables, banners and helpers.
They need `docker` and `jq`. Compose tools also need `docker compose` v2.

```bash
sudo ./bin/dm install          # symlink dm + dm-* into /usr/local/bin
dm                             # list all commands
dm <command> --help            # per-command help
```

| Command | Group | What it does |
|---|---|---|
| `dm status` | Admin | Shows engine info, a disk gauge, and counts of containers, images, volumes and networks. Includes a container table (project, health, restarts, uptime, ports), `system df`, and alerts. |
| `dm images [-u]` | Admin | Image inventory with age coloring and "used by". `-u` checks each tag's registry digest without pulling. |
| `dm cleanup [-x]` | Admin | **Dry-run by default.** Lists stopped containers, dangling/unused images, unused networks and build cache with sizes. Volumes are opt-in (`-v`). |
| `dm health` | Monitor | Checks state, healthcheck, OOM kills, exit codes, restart loops and restart policy. Exits `0` when OK, `1` on warnings, `2` on failures. `--json` and `--quiet` suit cron. |
| `dm monitor` | Monitor | Live CPU/memory/net/block dashboard with bars and thresholds. Supports `--once`, `--sort`, `--top`. |
| `dm logs scan` | Monitor | Error and warning counts plus error rate per container over a time window, with recent error samples. |
| `dm logs tail` | Monitor | Follows many containers at once with colored name prefixes. `-e` shows only errors, `-g REGEX` filters. |
| `dm doc` | Document | Writes a Markdown inventory: host, compose projects, containers, port map, volumes (and who uses them), bind mounts, networks and images. `-e` adds env vars, with secrets masked. |
| `dm compose-extract` | Compose | Reverse-engineers compose YAML from running containers. It emits only the settings that differ from the image defaults. `-p PROJECT`, `--all --split DIR`, `-r` redacts secrets. The result is validated with `compose config`. |
| `dm compose-new` | Compose | Scaffolds `compose.yaml`, `.env` (random secrets, mode 600), `.gitignore` and `README.md`. Templates: `generic`, `postgres`, `mariadb`, `redis`, `nginx`, `webapp` (app + postgres + redis). |
| `dm compose-lint` | Compose | Validates compose files and audits them: `:latest` tags, hard-coded secrets, docker.sock mounts, privileged mode, DB ports on 0.0.0.0, missing restart policy, healthcheck, log rotation and limits. |

### Examples

```bash
dm status -a                                   # include stopped containers
dm health -q || notify-send "docker unhealthy" # cron-friendly
dm monitor -s mem -n 10                        # top 10 by memory, refreshes every 5s
dm logs scan -s 7d -p grafana                  # a week of grafana log errors
dm logs tail -e                                # errors/warnings from all running containers
dm cleanup -x -I --older-than 168h             # remove images unused for a week (with prompt)
dm doc -o docs/$(hostname).md                  # document this host
dm compose-extract -p jira -r -o jira/compose.yaml
dm compose-extract --all --split ./extracted   # one compose.yaml per project/container
dm compose-new -t postgres -d /opt/stacks mydb
dm compose-lint .                              # audit every compose file in this repo
```

### Cron example

```cron
# Every 15 min: log only problems; non-zero exit can drive alerting
*/15 * * * * /usr/local/bin/dm-health -q >> /var/log/dm-health.log 2>&1
# Weekly inventory snapshot
0 6 * * 1  /usr/local/bin/dm-doc -o /mnt/nas_backups/docs/$(hostname)-$(date +\%F).md
```

### Output & colors

- Colors turn off automatically when output is piped or redirected. Set `NO_COLOR=1` to disable them, or `FORCE_COLOR=1` to force them on (for example with `less -R`).
- Tables stay aligned with colored cells and Unicode glyphs under both `mawk` and `gawk`.
- Destructive actions (`cleanup -x`) ask for confirmation. `-y` skips the prompt.

### Notes on `compose-extract`

- Named volumes and custom networks are declared `external: true`, so the generated stack reuses existing data.
- If you plan to `docker compose down` the original project, pass `--managed-networks`, because `down` deletes its networks.
- Literal `$` in values is escaped as `$$` so that Compose does not interpolate it.
- Settings that only exist at runtime (such as secrets passed with `-e`) are captured verbatim unless you pass `-r`. Review the output before you commit it.
