# Redis/Dragonfly Configuration for KumoMTA

## 📋 Overview

KumoMTA uses Redis (or Dragonfly, Redis-compatible) for shared throttles and connection limits across instances.

## 🔧 Current Configuration

### Dragonfly Service

- **Namespace**: `dragonflydb`
- **Service name**: `dragonflydb`
- **Port**: `6379` (standard Redis port)
- **Endpoint**: `dragonflydb.dragonflydb.svc.cluster.local:6379`

### Environment Variables

In `values.yaml`, Redis is configured as:

```yaml
env:
  - name: KUMOMTA_REDIS_HOST
    value: "redis://dragonflydb.dragonflydb.svc.cluster.local:6379"
```

## 📝 Redis URL Format

The Redis URL format is:
```
redis://[username:password@]host:port[/database]
```

**Examples**:
- No authentication: `redis://dragonflydb.dragonflydb.svc.cluster.local:6379`
- With authentication: `redis://username:password@dragonflydb.dragonflydb.svc.cluster.local:6379`
- With database: `redis://dragonflydb.dragonflydb.svc.cluster.local:6379/0`

## 🔍 Verification

### Verify Dragonfly Is Reachable

1. **From a KumoMTA pod**:
   ```bash
   kubectl exec -it <kumomta-pod> -- sh
   # Test Redis connection
   redis-cli -h dragonflydb.dragonflydb.svc.cluster.local -p 6379 ping
   ```

2. **Check KumoMTA logs**:
   ```bash
   kubectl logs -f <kumomta-pod> | grep -i redis
   ```

3. **Check Dragonfly service**:
   ```bash
   kubectl get svc -n dragonflydb dragonflydb
   kubectl get endpoints -n dragonflydb dragonflydb
   ```

## ⚙️ Advanced Configuration Options

### Redis Cluster Mode

If using Redis Cluster (not Dragonfly), enable cluster mode:

```yaml
env:
  - name: KUMOMTA_REDIS_CLUSTER_MODE
    value: "true"
```

**Note**: Dragonfly is Redis-compatible but runs as a single node. Do not enable cluster mode with Dragonfly.

### Connection Pool Size

Adjust the Redis connection pool size:

```yaml
env:
  - name: KUMOMTA_REDIS_POOL_SIZE
    value: "200"  # Default: 100
```

### Read from Replicas

For Redis with replicas, enable reading from replicas:

```yaml
env:
  - name: KUMOMTA_REDIS_READ_FROM_REPLICAS
    value: "true"  # Default: true
```

### Redis Authentication

If Dragonfly/Redis requires authentication:

```yaml
env:
  - name: KUMOMTA_REDIS_USERNAME
    value: "my-username"
  - name: KUMOMTA_REDIS_PASSWORD
    value: "my-password"
```

Or use a Kubernetes Secret:

```yaml
env:
  - name: KUMOMTA_REDIS_USERNAME
    valueFrom:
      secretKeyRef:
        name: dragonfly-credentials
        key: username
  - name: KUMOMTA_REDIS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: dragonfly-credentials
        key: password
```

## 🔄 Usage in init.lua

Redis is configured in `kumo-configs/init.lua`:

```lua
kumo.configure_redis_throttles({
  node = os.getenv("KUMOMTA_REDIS_HOST") or "redis://kumomta-redis",
  cluster = REDIS_CLUSTER_MODE,
  pool_size = os.getenv("KUMOMTA_REDIS_POOL_SIZE") or 100,
  read_from_replicas = os.getenv("KUMOMTA_REDIS_READ_FROM_REPLICAS") or true,
  username = os.getenv("KUMOMTA_REDIS_USERNAME") or nil,
  password = os.getenv("KUMOMTA_REDIS_PASSWORD") or nil,
})
```

## 🧪 Tests

### Connection Test from KumoMTA

1. **Create a test pod**:
   ```bash
   kubectl run redis-test --image=redis:alpine --rm -it -- sh
   ```

2. **Test connection**:
   ```bash
   redis-cli -h dragonflydb.dragonflydb.svc.cluster.local -p 6379 ping
   # Should reply: PONG
   ```

3. **Test operations**:
   ```bash
   redis-cli -h dragonflydb.dragonflydb.svc.cluster.local -p 6379 SET test "value"
   redis-cli -h dragonflydb.dragonflydb.svc.cluster.local -p 6379 GET test
   ```

## ⚠️ Important Notes

1. **Dragonfly vs Redis**: Dragonfly is compatible with the Redis protocol but runs as a single node. Do not use Redis cluster mode with Dragonfly.

2. **Performance**: Dragonfly is tuned for performance and can handle large in-memory datasets.

3. **Persistence**: Check Dragonfly persistence settings for your needs.

4. **Network**: Ensure KumoMTA pods can reach the Dragonfly service in the `dragonflydb` namespace.

5. **Port**: By default Dragonfly uses port 6379 (standard Redis). Confirm if your setup uses a different port.

## 🔗 References

- KumoMTA Redis throttles: https://docs.kumomta.com/userguide/configuration/throttles/
- Dragonfly: https://www.dragonflydb.io/docs
