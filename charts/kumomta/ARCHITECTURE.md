# KumoMTA Architecture for example.com

This document describes the architecture and technical choices for deploying KumoMTA on Kubernetes for the **example.com** domain.

## 🏗️ Overview

### Main Components

```
┌───────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                     │
│                                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │   MTA Pod 1  │  │   MTA Pod 2  │  │   MTA Pod N  │     │
│  │ (StatefulSet)│  │ (StatefulSet)│  │ (StatefulSet)│     │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘     │
│         │                  │                 │            │
│         └──────────────────┼─────────────────┘            │
│                            │                              │
│         ┌──────────────────┴──────────────────┐           │
│         │                                     │           │
│  ┌──────▼──────┐                      ┌───────▼──────┐    │
│  │ TSA Pods    │                      │    Redis     │    │
│  │(StatefulSet)│                      │  (Throttles) │    │
│  └─────────────┘                      └──────────────┘    │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐  │
│  │              ConfigMaps & Secrets                   │  │
│  │  - kumo-configs (Lua/TOML)                          │  │
│  │  - dkim-keys (DKIM private keys)                    │  │
│  │  - http-listener-keys (API auth)                    │  │
│  └─────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

## 📦 Detailed Components

### 1. MTA Pods (StatefulSet)

**Type**: `StatefulSet`

**Role**: Outbound email delivery

**Features**:
- **Persistence**: PVC for spools (message queues)
- **Scaling**: Horizontal via HPA or manual
- **Networking**: ClusterIP service for HTTP API and SMTP

**Volumes**:
- `spool`: PVC (25Gi) for persistent queues
- `kumo-configs`: ConfigMap with Lua/TOML configuration
- `dkim-keys`: Secret with DKIM private keys
- `http-listener-keys`: Secret with API credentials
- `kumo-logs`: EmptyDir for logs

**Configuration**:
- Lua Policy: `init.lua`
- Ports: 8000 (HTTP), 8080 (metrics), 2500 (SMTP)

### 2. TSA Pods (StatefulSet)

**Type**: `StatefulSet`

**Role**: Traffic Shaping Automation - dynamically adjusts sending rates

**Features**:
- **StatefulSet**: For stable hostnames (required for config)
- **Service**: Headless for discovery, ClusterIP for subscribe
- **Scaling**: Generally 1-3 replicas

**Configuration**:
- Lua Policy: `tsa_init.lua`
- Port: 8008 (HTTP API)

### 3. Redis/Dragonfly

**Role**: Shared throttles across all MTA pods

**Features**:
- Throttle coordination between pods
- Support for `CL_THROTTLE` (Dragonfly or redis-cell)
- Configuration via environment variables

**Configuration**:
- Deployed in the `dragonflydb` namespace
- Service accessible via: `dragonfly.dragonflydb.svc.cluster.local:6379`
- Configured in `values.yaml`: `KUMOMTA_REDIS_HOST=redis://dragonfly.dragonflydb.svc.cluster.local`

### 4. Sink

**Type**: `Deployment`

**Role**: Accept and drop emails (for testing)

**Configuration**:
- **Enabled by default** in `values.yaml`
- All emails are routed to the sink pod instead of real recipients
- Environment variable: `KUMOMTA_SINK_ENABLED=true`
- Endpoint configured via: `KUMOMTA_SINK_ENDPOINT`

**Usage**:
- For testing: leave enabled (default)
- For production: disable by setting `KUMOMTA_SINK_ENABLED=false`

## 🔧 Configuration

### Lua Policy (`init.lua`)

Modular structure with:

1. **Setup**: Loading helpers (sources, DKIM, shaping, queues)
2. **Init Handler**: Configuration at startup (spools, Redis, listeners)
3. **Event Handlers**:
   - `http_message_generated`: Processing injected messages
   - `get_egress_path_config`: Shaping configuration
   - `http_server_validate_auth_basic`: HTTP authentication

### TOML Files

#### `dkim_data.toml`
- DKIM configuration for `example.com`
- Keys loaded from Kubernetes Secrets
- Selector: `default`
- Algorithm: `sha256`

#### `sources.toml`
- Source IP configuration
- `shared` pool for general use
- Extensible for multiple IP pools

#### `queues.toml`
- Message lifecycle management
- Configuration by tenant/domain/campaign
- Max age: 24h by default

#### `shaping.toml`
- Rate limiting and connection limits
- Configuration by domain
- TSA dynamically adjusts these values

## 🔐 Security

### Kubernetes Secrets

Secrets are automatically created by the Helm chart by default (configurable in `values.yaml`):

1. **dkim-keys**: DKIM private keys
   - Created automatically if `secrets.dkim.create: true` (default)
   - Mounted read-only
   - Path: `/opt/kumomta/etc/policy/dkim/`
   - Configure via `secrets.dkim.defaultKey` or `secrets.dkim.keys` in `values.yaml`

2. **http-listener-keys**: HTTP API credentials
   - Created automatically if `secrets.httpListener.create: true` (default)
   - Format: username = file, password = content
   - Path: `/opt/kumomta/etc/http_listener_keys/`
   - Configure via `secrets.httpListener.defaultPassword` or `secrets.httpListener.keys` in `values.yaml`

To manage secrets externally, set `create: false` in `values.yaml` and create them manually.

### Best Practices

- ✅ Secrets stored in Kubernetes (encrypted at rest if enabled)
- ✅ Volumes mounted read-only
- ✅ ServiceAccount with minimal permissions
- ✅ TLS recommended for outbound SMTP (`enable_tls = "Required"`)
- ✅ HTTP Basic authentication for API
- ✅ Change default secrets for production deployments

## 📊 Observability

### Logs

- **Local**: `/var/log/kumomta/` (mounted as EmptyDir)
- **Collection**: Via sidecar or DaemonSet (Fluentd, etc.)
- **Format**: KumoMTA structured logs

### Metrics

- **Port**: 8080 (metrics)
- **Format**: Prometheus
- **ServiceMonitor**: Enableable via `serviceMonitor.enabled`

### Health Checks

- **Readiness**: `/api/check-liveness/v1`
- **Liveness**: Configurable (disabled by default)

## 🚀 Scaling

### Horizontal Scaling

**MTA Pods**:
- Autoscaling via HPA (CPU-based)
- Manual scaling: `kubectl scale statefulset kumomta --replicas=N`
- **Note**: Each pod has its own PVC (isolated queues)

**TSA Pods**:
- Generally 1-3 replicas
- StatefulSet for stable hostnames

### Vertical Scaling

Adjust resources in `values.yaml`:
```yaml
resources:
  requests:
    cpu: 1000m
    memory: 2Gi
  limits:
    cpu: 2000m
    memory: 4Gi
```

## 🔄 Email Processing Flow

```
1. HTTP Injection
   ↓
2. http_message_generated event
   ↓
3. Conformance check & fix
   ↓
4. Queue assignment (queues.toml)
   ↓
5. Routing (sources.toml → IP pool)
   ↓
6. DKIM signing (dkim_data.toml)
   ↓
7. Queue → Spool (persistent storage)
   ↓
8. Shaping (shaping.toml + TSA)
   ↓
9. SMTP delivery
   ↓
10. Retry logic (queues.toml)
```

## 🎯 Justified Technical Choices

### StatefulSet vs Deployment

**Choice**: `StatefulSet` for MTA and TSA

**Reasons**:
- ✅ Persistent queues (PVC per pod)
- ✅ Stable hostnames (required for TSA)
- ✅ Controlled startup order
- ✅ Ordered scaling

### PVC for Spools

**Choice**: `ReadWriteOnce` PVC of 25Gi

**Reasons**:
- ✅ Queue persistence between restarts
- ✅ Local performance (no network)
- ✅ Isolation per pod

### Redis for Throttles

**Choice**: Shared Redis (Dragonfly)

**Reasons**:
- ✅ Coordination between pods
- ✅ `CL_THROTTLE` support
- ✅ High performance
- ✅ Simple to deploy

### ConfigMap for Configuration

**Choice**: ConfigMap for Lua/TOML

**Reasons**:
- ✅ Versioning via Git
- ✅ Hot-reload possible (pod restart)
- ✅ Config/data separation

### Secrets for DKIM Keys

**Choice**: Kubernetes Secrets

**Reasons**:
- ✅ Security (encrypted at rest)
- ✅ Native K8s integration
- ✅ Easy rotation

**Alternative**: Hashicorp Vault (configurable in `dkim_data.toml`)

## 🔮 Future Improvements

### Short Term

- [ ] Enable TLS required by default
- [ ] Configure specific domains in `shaping.toml`
- [ ] Add custom metrics
- [ ] Configure Prometheus alerts

### Medium Term

- [ ] Multi-domain (multiple sending domains)
- [ ] Multiple IP pools (progressive warm-up)
- [ ] Hashicorp Vault integration
- [ ] Webhooks for events

### Long Term

- [ ] Advanced HA (multi-zone)
- [ ] Disaster recovery (backup/restore spools)
- [ ] Auto-scaling based on queue depth
- [ ] Integration with reputation systems

## 📚 References

- [KumoMTA Documentation](https://docs.kumomta.com/)
- [Configuration Concepts](https://docs.kumomta.com/userguide/configuration/concepts/)
- [Many Nodes Architecture](https://docs.kumomta.com/userguide/clustering/deployment/)
- [Traffic Shaping](https://docs.kumomta.com/userguide/configuration/trafficshaping/)
