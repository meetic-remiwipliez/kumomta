# Helm Chart KumoMTA for example.com

This Helm chart deploys KumoMTA on Kubernetes, configured for the **example.com** domain.

## 📋 Overview

KumoMTA is a high-performance MTA (Mail Transfer Agent) designed for sending large volumes of emails. This chart deploys a "Many Nodes" architecture with:

- **MTA Pods**: StatefulSet for email delivery
- **TSA Pods**: StatefulSet for Traffic Shaping Automation
- **Redis**: For shared throttles
- **Sink** (optional): For testing

## 🚀 Quick Start

### 1. Prerequisites

- Kubernetes cluster
- Helm 3.x
- **Dragonfly deployed in the `dragonflydb` namespace**
- DKIM keys generated

**Note**: SINK mode is enabled by default. All emails will be routed to the sink pod for testing. To disable, set `KUMOMTA_SINK_ENABLED=false` in `values.yaml`.

### 2. Configure Secrets (Optional)

**Note**: Secrets are automatically created by the chart with default test values. For production, customize them in `values.yaml`:

```yaml
secrets:
  dkim:
    create: true  # Set to false if managing externally
    # Generate: openssl genrsa 2048 | base64
    defaultKey: "<your-base64-encoded-dkim-key>"
  httpListener:
    create: true  # Set to false if managing externally
    # Generate: openssl rand -hex 16
    defaultPassword: "<your-secure-password>"
```

See `values.yaml` for more configuration options.

### 3. Deploy

```bash
helm install kumomta ./charts/kumomta \
  --namespace kumomta \
  --create-namespace
```

### 4. Test

```bash
# Port-forward
kubectl port-forward -n kumomta svc/kumomta 8000:8000

# Inject an email
curl -X POST \
  -H "Content-Type: application/json" \
  -u "api-user:$(kubectl get secret http-listener-keys -n kumomta -o jsonpath='{.data.api-user}' | base64 -d)" \
  http://localhost:8000/api/inject/v1 \
  -d '{
    "sender": "test@example.com",
    "recipient": "recipient@example.com",
    "subject": "Test",
    "body": "Test email"
  }'
```

## 📁 File Structure

```
charts/kumomta/
├── Chart.yaml                 # Chart metadata
├── values.yaml                # Default values
├── kumo-configs/              # KumoMTA configuration
│   ├── init.lua              # Main policy (routing, DKIM, shaping)
│   ├── dkim_data.toml        # DKIM configuration for example.com
│   ├── sources.toml          # Source IP configuration
│   ├── queues.toml           # Queue management
│   └── shaping.toml           # Rate limiting and shaping
├── sink-configs/             # Sink configuration (testing)
│   └── sink.lua
├── templates/                # Helm templates
│   ├── statefulset.yaml      # MTA StatefulSet
│   ├── tsa-statefulset.yaml  # TSA StatefulSet
│   ├── configmap.yaml        # ConfigMap for configs
│   └── ...
├── examples/                 # Examples
│   └── dkim-secret-example.yaml
├── DEPLOYMENT.md            # Detailed deployment guide
├── ARCHITECTURE.md          # Architecture documentation
└── README.md                # This file
```

## ⚙️ Configuration

### Main Variables (`values.yaml`)

```yaml
# MTA replicas
replicaCount: 1

# KumoMTA image
image:
  repository: ghcr.io/kumocorp/kumomta
  tag: 2025.01.29-833f82a8

# Services
service:
  httpPort: 8000
  smtpPort: 2500
  metricsPort: 8080

# Volumes
volumes:
  - name: dkim-keys
    secret:
      secretName: dkim-keys
  - name: http-listener-keys
    secret:
      secretName: http-listener-keys

# PVC for spools
volumeClaimTemplates:
  - name: spool
    spec:
      resources:
        requests:
          storage: 25Gi
```

### KumoMTA Configuration

Configuration files are in `kumo-configs/`:

- **`init.lua`**: Main policy with routing, DKIM, shaping
- **`dkim_data.toml`**: DKIM configuration for `example.com`
- **`sources.toml`**: Source IPs and pools
- **`queues.toml`**: Message lifecycle management
- **`shaping.toml`**: Rate limiting and connection limits

## 🔐 Security

### Secrets Management

Secrets are automatically created by the Helm chart by default. Configure them in `values.yaml`:

1. **`dkim-keys`**: DKIM private keys
   - Created automatically if `secrets.dkim.create: true` (default)
   - Key: `example.com.default.key`
   - Mounted at: `/opt/kumomta/etc/policy/dkim/`
   - **Production**: Update `secrets.dkim.defaultKey` with your own key

2. **`http-listener-keys`**: HTTP API authentication
   - Created automatically if `secrets.httpListener.create: true` (default)
   - Format: username = file, password = content
   - Mounted at: `/opt/kumomta/etc/http_listener_keys/`
   - **Production**: Update `secrets.httpListener.defaultPassword` with a secure password

To manage secrets externally, set `create: false` in `values.yaml` and create them manually with `kubectl`.

### Best Practices

- ✅ Secrets stored in Kubernetes (encrypted at rest if enabled)
- ✅ Volumes mounted read-only
- ✅ TLS recommended for SMTP (`enable_tls = "Required"`)
- ✅ HTTP Basic authentication
- ✅ Change default secrets for production deployments

## 📊 Monitoring

### Prometheus Metrics

```yaml
serviceMonitor:
  enabled: true
```

Metrics available on port 8080.

### Logs

Logs available in `/var/log/kumomta/` (mounted as EmptyDir).

Collection recommended via sidecar or DaemonSet.

## 🔄 Scaling

### Horizontal

```bash
# Manual scaling
kubectl scale statefulset kumomta -n kumomta --replicas=3

# Autoscaling (via HPA)
# Enable in values.yaml:
#   autoscaling:
#     enabled: true
#     minReplicas: 2
#     maxReplicas: 10
```

### Vertical

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

## 🧪 Testing

### Health check

```bash
curl http://localhost:8000/api/check-liveness/v1
```

### HTTP Injection

See "Quick Start" section above.

### SMTP (if listener enabled)

```bash
swaks --to test@example.com --from sender@example.com \
  --server localhost:2500
```

## 📚 Documentation

- **[deployment.md](deployment.md)**: Detailed deployment guide
- **[architecture.md](architecture.md)**: Architecture and technical choices
- **examples/dkim-secret-example.yaml**: DKIM Secret example

## 🔗 Useful Links

- [KumoMTA Documentation](https://docs.kumomta.com/)
- [Configuration Concepts](https://docs.kumomta.com/userguide/configuration/concepts/)
- [Many Nodes Architecture](https://docs.kumomta.com/userguide/clustering/deployment/)

## 🐛 Troubleshooting

### Pods in CrashLoopBackOff

```bash
# Check logs
kubectl logs -n kumomta <pod-name> --previous

# Check events
kubectl describe pod -n kumomta <pod-name>
```

### Emails Not DKIM Signed

1. Verify DKIM Secret:
   ```bash
   kubectl get secret dkim-keys -n kumomta
   ```

2. Verify mounting:
   ```bash
   kubectl exec -n kumomta <pod-name> -- ls -la /opt/kumomta/etc/policy/dkim/
   ```

3. Verify configuration in `dkim_data.toml`

### Redis/Dragonfly Issues

```bash
# Verify Dragonfly connectivity in the dragonflydb namespace
kubectl exec -n kumomta <pod-name> -- nc -zv dragonfly.dragonflydb.svc.cluster.local 6379

# Check environment variables
kubectl exec -n kumomta <pod-name> -- env | grep REDIS

# Verify Dragonfly is accessible
kubectl get svc -n dragonflydb
```

## 🔄 Update

```bash
# Update chart
helm upgrade kumomta ./charts/kumomta \
  --namespace kumomta \
  --reuse-values
```

## 🗑️ Uninstallation

```bash
# Uninstall
helm uninstall kumomta --namespace kumomta

# Delete PVCs (warning: data loss)
kubectl delete pvc -n kumomta -l app.kubernetes.io/name=kumomta
```

## 📝 Notes

- **Domain**: Configuration for `example.com` - adapt for your domain
- **DKIM**: Requires a DNS TXT record: `default._domainkey.example.com`
- **Dragonfly**: Required for shared throttles, must be deployed in the `dragonflydb` namespace
- **SINK Mode**: Enabled by default - all emails are routed to the sink pod for testing
- **PVC**: Each MTA pod has its own PVC (isolated queues)

## 🤝 Contributing

To improve this chart:

1. Modify configuration files in `kumo-configs/`
2. Test locally with `helm template`
3. Document changes
4. Create a PR

---

**Version**: 0.1.0  
**KumoMTA Version**: 1.16.0  
**Domain**: example.com
