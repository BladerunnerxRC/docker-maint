# docker-maint

backup.sh — Docker Volume Backup Script <setup as a STACK created in Portainer that creates a temp container and schedule to start in CRON. The container will exit wit error '0' and remove temp container"

restore.sh — Docker Volume Restore + Stack Redeploy

docker_full_backup.yml -- Docker compose script to build a stack that creates a temp container 

reboot-safe.sh — Safe reboot for optiplex-docker: (1) drains the Swarm node and gracefully stops standalone containers, (2) syncs and reboots, (3) on boot a one-shot systemd unit re-activates the node, restarts the previously running containers, and health-checks the services. Flags: `-y`, `--dry-run`, `--no-reboot`, `post` (run restore manually). Log: /var/log/reboot-safe.log
