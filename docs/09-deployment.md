# 09 — On-premise deployment

## 1. Topology

```
                    ┌──────────────────────────────┐
   Devices ── TLS ──►│  nginx (TLS, rate limit)     │
                    └───────┬──────────────┬───────┘
                            │              │
                   ┌────────▼───────┐  ┌───▼──────────────┐
                   │ xmobile-api ×N │  │ xmobile-admin    │ (web dashboard, static)
                   └────────┬───────┘  └──────────────────┘
                            │
      ┌─────────────────────┼───────────────────────────┐
      │                     │                           │
┌─────▼──────┐     ┌────────▼────────┐        ┌─────────▼────────┐
│ PostgreSQL │     │     Redis       │        │      MinIO       │
│ + PostGIS  │     │ cache / streams │        │  attachments     │
│ (+replica) │     └─────────────────┘        └──────────────────┘
└─────┬──────┘
      │            ┌────────────────┐   ┌──────────────┐   ┌─────────┐
      └────────────│ xmobile-worker │   │  Keycloak    │   │ ClamAV  │
                   └────────┬───────┘   │ (AD/LDAP fed)│   └─────────┘
                            │           └──────────────┘
                     ┌──────▼───────┐
                     │ XInfo (LAN)  │
                     └──────────────┘
```

## 2. docker-compose (reference)

```yaml
services:
  db:
    image: postgis/postgis:16-3.4
    environment:
      POSTGRES_DB: xmobile
      POSTGRES_USER: xmobile
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    command: >
      postgres -c max_connections=200 -c shared_buffers=2GB -c work_mem=32MB
               -c maintenance_work_mem=512MB -c effective_cache_size=6GB
               -c wal_level=replica -c archive_mode=on
               -c archive_command='test ! -f /wal/%f && cp %p /wal/%f'
    volumes: [ pgdata:/var/lib/postgresql/data, walarchive:/wal, ./db/schema:/docker-entrypoint-initdb.d:ro ]

  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes --maxmemory 1gb --maxmemory-policy allkeys-lru
    volumes: [ redisdata:/data ]

  minio:
    image: minio/minio
    command: server /data --console-address ":9001"
    environment: { MINIO_ROOT_USER: xmobile, MINIO_ROOT_PASSWORD_FILE: /run/secrets/minio_password }
    volumes: [ miniodata:/data ]

  keycloak:
    image: quay.io/keycloak/keycloak:25.0
    command: start --hostname-strict=false --db=postgres
    environment: { KC_DB_URL: jdbc:postgresql://db:5432/keycloak }

  clamav:
    image: clamav/clamav:stable

  api:
    image: xmobile/api:${TAG}
    deploy: { replicas: 2 }
    environment:
      ConnectionStrings__Db: Host=db;Database=xmobile;Username=xmobile;Password=...
      Redis__Configuration: redis:6379
      Storage__Endpoint: http://minio:9000
      Auth__Authority: https://keycloak.internal/realms/xmobile
      XInfo__BaseUrl: http://xinfo.internal/api
    depends_on: [ db, redis, minio ]

  worker:
    image: xmobile/worker:${TAG}
    environment: *api_env
    depends_on: [ db, redis, minio ]

  nginx:
    image: nginx:alpine
    ports: [ "443:443" ]
    volumes: [ ./nginx.conf:/etc/nginx/nginx.conf:ro, ./certs:/certs:ro ]

volumes: { pgdata: , walarchive: , redisdata: , miniodata: }
```

Secrets come from Docker secrets or the customer's vault — never from the compose file.

## 3. Sizing

| Reps | API | Worker | Postgres | Storage/year |
|---|---|---|---|---|
| ≤ 100 | 1 × (2 vCPU, 2 GB) | 1 × (2 vCPU, 2 GB) | 4 vCPU, 8 GB | ~30 GB DB + ~60 GB attachments |
| 100–500 | 2 × (2 vCPU, 4 GB) | 1 × (4 vCPU, 4 GB) | 8 vCPU, 16 GB, SSD | ~120 GB DB + ~250 GB attachments |
| 500–2000 | 3–4 × (4 vCPU, 4 GB) | 2 × (4 vCPU, 8 GB) | 16 vCPU, 32 GB, NVMe + replica | ~450 GB DB + ~1 TB attachments |

Attachment estimate assumes ~4 receipts/rep/working day at ~200 KB after client-side
compression. Compressing on the device (not the server) is what keeps this manageable on
a field data connection as well as on disk.

## 4. Database operations

- **Partitions:** `PartitionMaintenance` creates the next month ahead of time and detaches
  partitions older than the retention window. Detached partitions are dumped to cold storage
  before being dropped.
- **Backups:** nightly `pg_basebackup` + continuous WAL archiving → RPO ≈ 15 min.
  MinIO versioning plus a weekly `mc mirror` to a second volume.
- **Restore drill:** quarterly, restoring into a scratch container and running the smoke
  suite. A backup that has never been restored is a hypothesis, not a backup.
- **Vacuum:** autovacuum tuned more aggressively on `location_ping` partitions and
  `sync.change_log` (high-churn, append-heavy).
- **Change-feed pruning:** `sync.change_log` grows forever if left alone. Rows older than the
  slowest device's cursor (with a floor of 30 days) are pruned weekly; a device whose cursor
  falls off the end is told to re-bootstrap.

## 5. Upgrades

1. Backwards-compatible DB migration first (expand), deployed while the old app runs.
2. Rolling API/worker deployment.
3. Contract cleanup migration (contract) only after all devices report the new app version.

The mobile fleet upgrades slowly and unevenly — reps are offline for days — so the API must
support **N-2 app versions**. Version negotiation happens at `/v1/auth/device`, which can
return a `minSupportedVersion` and a soft-nag flag before it ever returns a hard block.

## 6. Network policy

| Flow | Direction | Note |
|---|---|---|
| Devices → nginx:443 | Inbound | The only inbound path; devices are on mobile networks, so this must be reachable from outside the LAN (DMZ or VPN) |
| API/Worker → XInfo | Internal | LAN only |
| API/Worker → Keycloak/AD | Internal | LAN only |
| Worker → FCM/APNs | Outbound | Only external requirement; optional |
| XInfo → MinIO | Internal | Only if using presigned-URL receipt mode |

If the customer refuses any outbound internet access, push is disabled and the app polls on
foreground — documented in [06 §7](06-security-identity.md#7-push-notifications).

## 7. Monitoring on-prem

Minimum viable, because there may be no platform team:

- Container health checks and restart policies.
- A single `/health/ready` aggregate consumed by the customer's existing monitoring.
- A daily operations email: outbox depth, dead messages, reconciliation discrepancies,
  devices unsynced > 24 h, inference lag, disk headroom.
- Log rotation with a hard cap so a chatty error cannot fill the disk.
