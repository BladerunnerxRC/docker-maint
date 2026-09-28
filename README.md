# docker-maint

backup.sh — Docker Volume Backup Script <setup as a STACK created in Portainer that creates a temp container and schedule to start in CRON. The container will exit wit error '0' and remove temp container"

restore.sh — Docker Volume Restore + Stack Redeploy

docker_full_backup.yml -- Docker compose script to build a stack that creates a temp container 

## admin/ — Docker administration scripts

Standalone Bash scripts; run any of them with `-h` for full options. Each exits non-zero when it finds a problem, so they can be used as cron jobs or monitoring checks.

| Script | What it does |
| --- | --- |
| `docker-health.sh` | Reports unhealthy, restarting, crashed (non-zero exit) and frequently restarting containers, and Docker disk usage. `-q` prints only problems. |
| `docker-cleanup.sh` | Dry-run by default; `-y` prunes stopped containers, unused networks, dangling images and build cache older than `-t` (default 24h). `-a` all unused images, `-v` anonymous volumes. Named volumes are never removed. |
| `docker-update-check.sh` | Pulls each running container's image and reports newer versions. `-u` redeploys compose projects whose files are on the host; Portainer stacks are reported for redeploy in Portainer. |
| `volume-backup.sh` | Timestamped `tar.gz` backups of named volumes via a throwaway Alpine container, verified with `gzip -t`, keeping the newest `-k` (default 7). `-s` stops containers using the volume during backup (use for databases); `-A` backs up all named volumes. |
| `volume-restore.sh` | Restores a `volume-backup.sh` archive: stops the containers using the volume, empties it, extracts, restarts. |
| `container-log-scan.sh` | Counts error/fatal/panic/exception lines per container over `-s` (default 24h); `-v N` shows the last N matches. |

Labels: `docker-maint.keep=true` protects a container, image, network or volume from `docker-cleanup.sh`; `docker-maint.no-update=true` excludes a container from `docker-update-check.sh`.

Example cron (`crontab -e` as root):

```cron
15 2 * * * /opt/docker-maint/admin/volume-backup.sh -d /mnt/nas_backups -k 14 -s grafana_data jira_postgres_data >> /var/log/docker-backup.log 2>&1
0 * * * *  /opt/docker-maint/admin/docker-health.sh -q || echo "docker health check failed" | logger -t docker-health
30 3 * * 0 /opt/docker-maint/admin/docker-cleanup.sh -y -t 168h >> /var/log/docker-cleanup.log 2>&1
