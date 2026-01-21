# Debug Logging Configuration

## 📋 Overview

Debug mode is enabled for all KumoMTA components to support debugging and development.

## 🔧 Configuration

### Configured Components

1. **Main KumoMTA** (StatefulSet)
   - Environment variable: `KUMOD_LOG`
   - Diagnostic filters in `init.lua`

2. **TSA** (Traffic Shaping Automation)
   - Diagnostic filters in `tsa_init.lua`

3. **Sink**
   - Diagnostic filters in `sink.lua`

## 📝 Configuration Details

### Main KumoMTA

#### Environment Variable (`values.yaml`)

```yaml
env:
  - name: KUMOD_LOG
    value: "kumod=debug,lua=debug,http=debug,smtp=debug,queue=debug,egress=debug"
```

#### Diagnostic Filters (`init.lua`)

```lua
kumo.set_diagnostic_log_filter("kumod=debug,lua=debug,http=debug,smtp=debug,queue=debug,egress=debug,redis=debug")
```

**Enabled components**:
- `kumod`: Main daemon logs
- `lua`: Lua script logs
- `http`: HTTP server logs
- `smtp`: SMTP (inbound/outbound) logs
- `queue`: Queue management logs
- `egress`: Outbound connection logs
- `redis`: Redis operation logs

### TSA (Traffic Shaping Automation)

#### Diagnostic Filters (`tsa_init.lua`)

```lua
kumo.set_diagnostic_log_filter("tsa_daemon=debug,tsa=debug,http=debug,lua=debug")
```

**Enabled components**:
- `tsa_daemon`: TSA daemon logs
- `tsa`: General TSA logs
- `http`: TSA HTTP server logs
- `lua`: TSA Lua script logs

### Sink

#### Diagnostic Filters (`sink.lua`)

```lua
kumo.set_diagnostic_log_filter("kumod=debug,lua=debug,http=debug,smtp=debug")
```

**Enabled components**:
- `kumod`: Sink daemon logs
- `lua`: Lua script logs
- `http`: HTTP server logs
- `smtp`: SMTP logs

## 📊 Available Log Levels

- **trace**: Very verbose, full detail
- **debug**: Detailed debug information
- **info**: General information (default)
- **warn**: Warnings
- **error**: Errors only

## 🔍 Viewing Logs

### Main KumoMTA Logs

```bash
# Main pod logs
kubectl logs -f <kumomta-pod-name>

# Logs from volume
kubectl exec -it <kumomta-pod-name> -- tail -f /var/log/kumomta/*.log
```

### TSA Logs

```bash
# TSA pod logs
kubectl logs -f <kumomta-tsa-pod-name>

# Logs from volume
kubectl exec -it <kumomta-tsa-pod-name> -- tail -f /var/log/kumo/*.log
```

### Sink Logs

```bash
# Sink pod logs
kubectl logs -f <kumomta-sink-pod-name>

# Logs from volume
kubectl exec -it <kumomta-sink-pod-name> -- tail -f /var/log/kumo/*.log
```

## 🧪 Tests

### Verify Debug Is Active

1. **Check environment variables**:
   ```bash
   kubectl exec -it <kumomta-pod-name> -- env | grep KUMOD_LOG
   ```

2. **Check startup logs**:
   ```bash
   kubectl logs <kumomta-pod-name> | grep -i "debug\|diagnostic"
   ```

3. **Test with kcli** (if available):
   ```bash
   kcli --endpoint http://<kumomta-pod>:8000 set-log-filter 'kumod=trace'
   ```

## ⚙️ Customization

### Changing Log Level

To change the log level for a specific component, edit the `KUMOD_LOG` variable:

```yaml
env:
  - name: KUMOD_LOG
    value: "kumod=trace,lua=debug,http=info"
```

### Disabling Debug

To disable debug and return to info level:

```yaml
env:
  - name: KUMOD_LOG
    value: "kumod=info,lua=info,http=info,smtp=info,queue=info,egress=info"
```

And comment out or remove the `kumo.set_diagnostic_log_filter()` calls in the Lua files.

## ⚠️ Important Notes

1. **Performance**: Debug mode produces many more logs and can affect performance. Use it only for development and debugging.

2. **Storage**: Debug logs can fill volumes quickly. Monitor disk usage.

3. **Production**: In production, use `info` or `warn` to reduce log volume.

4. **Multiple filters**: Filters can be combined with commas: `component1=level1,component2=level2`

5. **Override**: The `KUMOD_LOG` environment variable can override filters defined in Lua files.

## 🔗 References

- KumoMTA logging: https://docs.kumomta.com/userguide/configuration/logging/
- KumoMTA troubleshooting: https://docs.kumomta.com/userguide/operation/troubleshooting/
- set_diagnostic_log_filter API: https://docs.kumomta.com/reference/kumo/set_diagnostic_log_filter
