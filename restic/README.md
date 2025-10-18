
Portainer‑ready stack file you can drop in that runs Backrest (for server‑level backups with a browser GUI) and Stack‑Back (for Docker volume backups) side‑by‑side. Each points to its own subdirectory on your NFS share so they don’t collide:

Backrest

- Exposes a web UI on http://<host>:8081
- Backs up /etc, /home, or any other directories you mount
- Stores snapshots in /mnt/restic-backups/optiplex/server

Stack‑Back

- Runs headless, schedules backups of Docker volumes
- Stores snapshots in /mnt/restic-backups/optiplex/docker

NFS Mount
- You can either mount /mnt/restic-backups on the host and bind it in, or uncomment the restic_nfs volume definition to let Docker mount it directly.
