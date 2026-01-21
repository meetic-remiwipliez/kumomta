# HTTP Listener Keys Secret Configuration

## 📋 Overview

The `http-listener-keys` secret is used for KumoMTA HTTP API authentication. This secret is now created automatically by the Helm chart.

## 🔧 Configuration

### Enabling

The secret is enabled by default in `values.yaml`:

```yaml
httpListenerKeys:
  enabled: true
  secretName: http-listener-keys
  users:
    user1: "default-password"
```

### Secret Structure

The secret stores username/password pairs:
- **Key**: username
- **Value**: password (automatically base64-encoded)

Each key in the secret corresponds to a file in `/opt/kumomta/etc/http_listener_keys/` in the pod.

## 🔐 Generating Secure Passwords

### Recommended Method

```bash
# Generate a random password (16 bytes = 32 hex characters)
openssl rand -hex 16
```

### Example Configuration

```yaml
httpListenerKeys:
  enabled: true
  secretName: http-listener-keys
  users:
    admin: "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6"  # Generated with openssl rand -hex 16
    api-user: "f6e5d4c3b2a19876543210fedcba987"  # Another user
    test-user: "1234567890abcdef1234567890abcdef"  # For testing
```

## 📝 Usage

### HTTP API Authentication

Credentials are used for Basic Auth on the HTTP API:

```bash
# Example authenticated request
curl -u user1:default-password \
  http://kumomta:8000/api/v1/inject \
  -H "Content-Type: application/json" \
  -d @message.json
```

### How It Works in init.lua

The code in `init.lua` reads files from the mounted volume:

```lua
function get_auth(user, password)
  local file = "/opt/kumomta/etc/http_listener_keys/" .. user
  if not cached_auth_file_exists(file) then
    return false
  end
  for line in io.lines(file) do
    if password == line then
      return true
    end
  end
  return false
end
```

## ⚙️ Customization

### Adding Users

Edit `values.yaml`:

```yaml
httpListenerKeys:
  enabled: true
  secretName: http-listener-keys
  users:
    user1: "password1"
    user2: "password2"
    admin: "secure-admin-password"
    api-service: "api-password"
```

### Disabling Secret Creation

If you prefer to create the secret manually:

```yaml
httpListenerKeys:
  enabled: false
```

Then create the secret manually:

```bash
kubectl create secret generic http-listener-keys \
  --from-literal=user1=password1 \
  --from-literal=admin=admin-password
```

### Using an Existing Secret

If you already have a secret with a different name, update the volumes in `values.yaml`:

```yaml
volumes:
  - name: http-listener-keys
    secret:
      secretName: my-existing-secret
      optional: false
```

## 🔍 Verification

### Verify the Secret Exists

```bash
kubectl get secret http-listener-keys
```

### Verify Content (decoded)

```bash
kubectl get secret http-listener-keys -o jsonpath='{.data.user1}' | base64 -d
```

### Verify in the Pod

```bash
kubectl exec -it <kumomta-pod> -- ls -la /opt/kumomta/etc/http_listener_keys/
kubectl exec -it <kumomta-pod> -- cat /opt/kumomta/etc/http_listener_keys/user1
```

## ⚠️ Important Notes

1. **Security**: Change the default password in production.
2. **Base64**: Passwords are automatically base64-encoded by Helm.
3. **Format**: Values in the secret must be plain text (Helm encodes them).
4. **Mount**: The secret is mounted as individual files (one key = one file).
5. **Sync**: After changing the secret, pods must be restarted to pick up changes.

## 🔄 Migration from extraManifests

If you used `extraManifests` to create the secret (e.g. in `values.localdev.yaml`), you can now:

1. **Remove** the secret section from `extraManifests`
2. **Use** the new `httpListenerKeys` section in `values.yaml`

### Old Method (extraManifests)

```yaml
extraManifests:
  - apiVersion: v1
    kind: Secret
    metadata:
      name: http-listener-keys
    data:
      user1: "ZGZhZDYxNDNiNDUyMGY4NTI2ZTRmOWEwYjI1YWI0MmI="  # base64 encoded
```

### New Method (httpListenerKeys)

```yaml
httpListenerKeys:
  enabled: true
  secretName: http-listener-keys
  users:
    user1: "default-password"  # plain text, encoded automatically
```

## 🔗 References

- KumoMTA HTTP API: https://docs.kumomta.com/userguide/configuration/httplisteners/
- Kubernetes Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
