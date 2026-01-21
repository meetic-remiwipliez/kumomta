# Sink Mode Enabled by Default

## 📋 Overview

**Sink** mode is enabled by default in the Helm chart to allow safe testing without sending real email.

## 🔧 Configuration

### Environment Variables

In `values.yaml`, the following variables are set:

```yaml
env:
  - name: KUMOMTA_SINK_ENABLED
    value: "true"
  - name: KUMOMTA_SINK_ENDPOINT
    value: "kumomta-kumomta-sink.default.svc.cluster.local"
```

### How It Works

When `KUMOMTA_SINK_ENABLED` is set to `"true"`:
- All email is redirected to the sink service instead of being sent for real
- The sink accepts email via SMTP (port 25) and HTTP (port 8000)
- Messages are accepted and then dropped immediately (no real delivery)

### Sink Service

The sink service is deployed automatically when `sink.enabled: true` in `values.yaml` (default).

The service name follows the pattern:
```
{{ release-name }}-kumomta-sink.{{ namespace }}.svc.cluster.local
```

**Example**:
- Release name: `kumomta`
- Namespace: `default`
- Service name: `kumomta-kumomta-sink.default.svc.cluster.local`

## 🧪 Tests

### Verify Sink Is Active

1. **Check logs**:
   ```bash
   kubectl logs -f deployment/kumomta-kumomta-sink
   ```

2. **Send a test email**:
   ```bash
   curl -X POST http://kumomta:8000/api/v1/inject \
     -H "Content-Type: application/json" \
     -d '{
       "sender": "test@example.com",
       "recipient": "dest@example.com",
       "headers": {"Subject": "Test"},
       "body": "Test message"
     }'
   ```

3. **Check sink logs**:
   - The message should appear in the sink logs
   - The message should NOT be sent to the real address

### Disabling Sink Mode

To disable sink mode and send real email:

1. **Edit `values.yaml`**:
   ```yaml
   env:
     - name: KUMOMTA_SINK_ENABLED
       value: "false"  # or remove this variable
   ```

2. **Or use an override**:
   ```yaml
   # values-production.yaml
   env:
     - name: KUMOMTA_SINK_ENABLED
       value: "false"
   ```

3. **Redeploy**:
   ```bash
   helm upgrade kumomta ./charts/kumomta -f values-production.yaml
   ```

## ⚠️ Important Notes

1. **Sink endpoint**: Ensure `KUMOMTA_SINK_ENDPOINT` matches the actual sink service name in your cluster. Adjust for your release name and namespace.

2. **Namespace**: The default namespace is `default`. If you deploy in another namespace, update the endpoint.

3. **Security**: Sink mode is for testing. Do not use it in production without understanding the impact.

4. **Sink service**: The sink service must be deployed and running for sink mode to work. Ensure `sink.enabled: true` in `values.yaml`.

## 📝 Configuration in init.lua

Sink mode is handled in `kumo-configs/init.lua`:

```lua
if os.getenv("KUMOMTA_SINK_ENABLED") == "true" then
  msg:set_meta("routing_domain", os.getenv("KUMOMTA_SINK_ENDPOINT") or "kumomta-sink.default.svc.cluster.local")
end
```

This sets `routing_domain` so all email is sent to the sink.
