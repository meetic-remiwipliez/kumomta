# KumoMTA Deployment Guide for example.com

This guide describes how to deploy KumoMTA on Kubernetes for the **example.com** domain.

## 📋 Prerequisites

- Functional Kubernetes cluster
- Helm 3.x installed
- kubectl access configured
- **Dragonfly deployed in the `dragonflydb` namespace** (for shared throttles)
- DKIM keys generated for example.com

**Note**: SINK mode is enabled by default in `values.yaml`. All emails will be routed to the sink pod instead of real recipients. To disable SINK mode, set `KUMOMTA_SINK_ENABLED=false` in `values.yaml`.

## 🏗️ Architecture

The deployment includes:

1. **MTA Pods (StatefulSet)**: Outbound email delivery
2. **TSA Pods (StatefulSet)**: Traffic Shaping Automation
3. **Sink Pod (Deployment, optional)**: For testing
4. **Redis**: Shared throttles between pods
5. **ConfigMaps**: Lua and TOML configuration
6. **Secrets**: DKIM keys and HTTP authentication

## 📦 Step 1: Secret Configuration

**Note**: Secrets are automatically created by the Helm chart by default. You can customize them before deployment or manage them externally.

### 1.1 Configure Secrets (Optional)

By default, the chart creates secrets with test values. For production, you should customize them in `values.yaml`:

#### DKIM Secret

The chart automatically creates the DKIM secret if `secrets.dkim.create: true` (default). To use your own DKIM key:

1. Generate your DKIM key:
```bash
# Generate private key
openssl genrsa -out example.com.default.key 2048

# Generate public key (for DNS)
openssl rsa -in example.com.default.key -pubout -out example.com.default.pub

# Extract public key in DNS format
openssl rsa -in example.com.default.key -pubout -outform DER | openssl base64 -A
```

2. Update `values.yaml`:
```yaml
secrets:
  dkim:
    create: true
    # Base64 encode your key: openssl genrsa 2048 | base64
    defaultKey: "<your-base64-encoded-key>"
    # Or use custom keys:
    # keys:
    #   example.com.default.key: "<base64-encoded-key>"
```

#### HTTP Listener Secret

The chart automatically creates the HTTP listener secret if `secrets.httpListener.create: true` (default). To use your own password:

1. Generate a secure password:
```bash
API_PASSWORD=$(openssl rand -hex 16)
```

2. Update `values.yaml`:
```yaml
secrets:
  httpListener:
    create: true
    # Plain text password (will be base64 encoded automatically)
    defaultPassword: "<your-secure-password>"
    # Or use custom keys:
    # keys:
    #   api-user: "<your-password>"
```

**Alternative**: If you prefer to manage secrets externally, set `create: false` in `values.yaml` and create them manually using `kubectl`:

```bash
# Create DKIM secret manually
kubectl create secret generic dkim-keys \
  --from-file=example.com.default.key=./example.com.default.key \
  --namespace=kumomta

# Create HTTP listener secret manually
kubectl create secret generic http-listener-keys \
  --from-literal=api-user="$(openssl rand -hex 16)" \
  --namespace=kumomta
```

### 1.2 Configure DKIM DNS

Add a TXT record in your DNS for example.com:

```
default._domainkey.example.com TXT "v=DKIM1; k=rsa; p=<your-public-key-base64>"
```

Verify with:
```bash
dig TXT default._domainkey.example.com
```

## 🚀 Step 2: Deployment with Helm

### 2.1 Verify Configuration

Examine `values.yaml` and customize secrets if needed (see Step 1):

```bash
cd charts/kumomta
cat values.yaml
```

**Important**: For production deployments, make sure to:
- Update `secrets.dkim.defaultKey` with your own DKIM key
- Update `secrets.httpListener.defaultPassword` with a secure password

### 2.2 Deploy KumoMTA

```bash
# From project root
helm install kumomta ./charts/kumomta \
  --namespace kumomta \
  --create-namespace \
  --values ./charts/kumomta/values.yaml
```

### 2.3 Verify Deployment

```bash
# Check pods
kubectl get pods -n kumomta

# Check services
kubectl get svc -n kumomta

# Check StatefulSets
kubectl get statefulset -n kumomta

# View logs
kubectl logs -n kumomta -l app.kubernetes.io/name=kumomta --tail=100
```

## 🧪 Step 3: Testing

### 3.1 Health Check

```bash
# Port-forward to HTTP service
kubectl port-forward -n kumomta svc/kumomta 8000:8000

# Test health endpoint
curl http://localhost:8000/api/check-liveness/v1
```

### 3.2 Inject Test Email

```bash
# Retrieve API password
API_PASSWORD=$(kubectl get secret http-listener-keys -n kumomta -o jsonpath='{.data.api-user}' | base64 -d)

# Inject email via HTTP API
curl -X POST \
  -H "Content-Type: application/json" \
  -u "api-user:${API_PASSWORD}" \
  http://localhost:8000/api/inject/v1 \
  -d '{
    "sender": "test@example.com",
    "recipient": "recipient@example.com",
    "subject": "Test Email from KumoMTA",
    "body": "This is a test email sent from KumoMTA."
  }'
```

### 3.3 Test with swaks (if installed)

```bash
# Port-forward SMTP
kubectl port-forward -n kumomta svc/kumomta 2500:2500

# Send email via SMTP
swaks \
  --to recipient@example.com \
  --from test@example.com \
  --server localhost:2500 \
  --auth LOGIN \
  --auth-user api-user \
  --auth-password "${API_PASSWORD}"
```

### 3.4 Check Logs

```bash
# MTA logs
kubectl logs -n kumomta -l app.kubernetes.io/name=kumomta --tail=50 -f

# TSA logs
kubectl logs -n kumomta -l app.kubernetes.io/name=kumomta-tsa --tail=50 -f
```

## 🔧 Step 4: Advanced Configuration

### 4.1 Modify Configuration

Configuration files are in `kumo-configs/`:

- `init.lua`: Main policy
- `dkim_data.toml`: DKIM configuration
- `sources.toml`: Source IP configuration
- `queues.toml`: Queue management
- `shaping.toml`: Shaping and rate limiting

After modification, update the ConfigMap:

```bash
# Reload ConfigMap
helm upgrade kumomta ./charts/kumomta \
  --namespace kumomta \
  --reuse-values

# Restart pods to apply changes
kubectl rollout restart statefulset/kumomta -n kumomta
```

### 4.2 Scaling

```bash
# Increase MTA replica count
kubectl scale statefulset kumomta -n kumomta --replicas=3

# Enable autoscaling (if configured)
# Modify values.yaml:
#   autoscaling:
#     enabled: true
#     minReplicas: 2
#     maxReplicas: 10
```

### 4.3 Monitoring

```bash
# Enable ServiceMonitor for Prometheus (if available)
# Modify values.yaml:
#   serviceMonitor:
#     enabled: true

# Access metrics
kubectl port-forward -n kumomta svc/kumomta 8080:8080
curl http://localhost:8080/metrics
```

## 🔒 Security

### Best Practices

1. **Secrets**: Use Kubernetes Secrets (encrypted at rest if enabled)
2. **RBAC**: Limit ServiceAccount permissions
3. **Network Policies**: Restrict network access if necessary
4. **TLS**: Enable TLS for outbound SMTP connections
5. **Authentication**: Use strong passwords for HTTP API

### DKIM Key Rotation

If secrets are managed by the chart:

1. Generate new key:
```bash
openssl genrsa -out example.com.default.new.key 2048
```

2. Update `values.yaml`:
```yaml
secrets:
  dkim:
    create: true
    defaultKey: "<base64-encoded-new-key>"  # openssl genrsa 2048 | base64
```

3. Upgrade the Helm release:
```bash
helm upgrade kumomta ./charts/kumomta \
  --namespace kumomta \
  --reuse-values
```

4. Update DNS with new public key

5. Restart pods:
```bash
kubectl rollout restart statefulset/kumomta -n kumomta
```

If secrets are managed externally:
```bash
# Update Secret manually
kubectl create secret generic dkim-keys \
  --from-file=example.com.default.key=./example.com.default.new.key \
  --namespace=kumomta \
  --dry-run=client -o yaml | kubectl apply -f -

# Update DNS and restart pods
kubectl rollout restart statefulset/kumomta -n kumomta
```

## 🐛 Troubleshooting

### Pods in CrashLoopBackOff

```bash
# Check logs
kubectl logs -n kumomta <pod-name> --previous

# Check events
kubectl describe pod -n kumomta <pod-name>

# Check ConfigMaps and Secrets
kubectl get configmap kumo-configs -n kumomta -o yaml
kubectl get secret dkim-keys -n kumomta -o yaml
```

### Emails Not DKIM Signed

1. Verify that DKIM Secret is mounted:
   ```bash
   kubectl exec -n kumomta <pod-name> -- ls -la /opt/kumomta/etc/policy/dkim/
   ```

2. Verify configuration in `dkim_data.toml`

3. Check logs for DKIM errors:
   ```bash
   kubectl logs -n kumomta <pod-name> | grep -i dkim
   ```

### Redis/Dragonfly Connection Issues

```bash
# Verify Dragonfly connectivity in the dragonflydb namespace
kubectl exec -n kumomta <pod-name> -- nc -zv dragonfly.dragonflydb.svc.cluster.local 6379

# Check environment variables
kubectl exec -n kumomta <pod-name> -- env | grep REDIS

# Verify Dragonfly is accessible
kubectl get svc -n dragonflydb
```

## 📚 Resources

- KumoMTA Documentation: https://docs.kumomta.com/
- Configuration concepts: https://docs.kumomta.com/userguide/configuration/concepts/
- API Reference: https://docs.kumomta.com/reference/

## 🔄 Update

```bash
# Update chart
helm upgrade kumomta ./charts/kumomta \
  --namespace kumomta \
  --reuse-values

# Or with new values
helm upgrade kumomta ./charts/kumomta \
  --namespace kumomta \
  --values ./charts/kumomta/values.production.yaml
```

## 🗑️ Uninstallation

```bash
# Uninstall KumoMTA
helm uninstall kumomta --namespace kumomta

# Delete PVCs (warning: data loss)
kubectl delete pvc -n kumomta -l app.kubernetes.io/name=kumomta

# Delete Secrets (optional)
kubectl delete secret dkim-keys http-listener-keys -n kumomta
```
