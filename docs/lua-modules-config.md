# Lua Modules Configuration in KumoMTA

## 📋 Overview

Custom Lua modules are loaded from the ConfigMap mounted at `/opt/kumomta/etc/policy/`.

## ⚠️ Important: Use `dofile()` Instead of `require()`

Kubernetes mounts ConfigMaps with paths containing slashes (`/`) as **individual files**, not as a directory tree.

For example, the file `kumo-configs/stir_talk.lua` is mounted as `stir_talk.lua` under `/opt/kumomta/etc/policy/`.

### Solution: Use `dofile()` with Absolute Path

Instead of:
```lua
require("stir_talk")  -- ❌ May not work with ConfigMap layout
```

Use:
```lua
dofile("/opt/kumomta/etc/policy/stir_talk.lua")  -- ✅ Works
```

## 📁 File Structure

```
kumo-configs/
├── init.lua                    → /opt/kumomta/etc/policy/init.lua
├── tsa_init.lua                → /opt/kumomta/etc/policy/tsa_init.lua
├── stir_talk.lua               → /opt/kumomta/etc/policy/stir_talk.lua  # Routing + egress path config
├── sources.toml
├── queues.toml
└── ...
```

The ConfigMap uses `kumo-configs/*`, so only files at the **root** of `kumo-configs/` are included. There is no `lua/` subdirectory.

## 🔧 Configuration in init.lua

### Loading Modules

```lua
-- Load StirTalk (routing logic + egress path configuration)
local stir_talk = dofile("/opt/kumomta/etc/policy/stir_talk.lua")
```

## 📝 Differences Between `require()` and `dofile()`

### `require()` (does not work with ConfigMap)

- Looks up in `package.path`
- Requires an actual directory structure
- Caches loaded modules
- Uses dots as separators: `require("module")`

### `dofile()` (recommended for ConfigMap)

- Loads directly from a file path
- Works with individual files mounted by ConfigMap
- Re-executes the file on each call (no cache)
- Uses absolute paths: `dofile("/opt/kumomta/etc/policy/module.lua")`

## 🔍 Verification

### Verify Files Are Mounted

```bash
# List files in the ConfigMap
kubectl get configmap kumo-configs -o jsonpath='{.data}' | jq 'keys'

# Check inside the pod
kubectl exec -it <kumomta-pod> -- ls -la /opt/kumomta/etc/policy/
```

### Verify File Content

```bash
kubectl exec -it <kumomta-pod> -- cat /opt/kumomta/etc/policy/stir_talk.lua
```

## 🧪 Tests

### Module Load Test

Add to `init.lua`:

```lua
-- Load test
local test_result = dofile("/opt/kumomta/etc/policy/stir_talk.lua")
kumo.log_info("Module loaded successfully")
```

## ⚙️ Alternative: Configure package.path

If you prefer `require()`, you can set `package.path` in `init.lua`:

```lua
-- Add the policy directory to package.path
package.path = package.path .. ";/opt/kumomta/etc/policy/?.lua;/opt/kumomta/etc/policy/?/init.lua"

-- Then you can use require() with relative paths
-- But this requires files to be accessible in the right format
-- Which does not always work with ConfigMap
```

**Note**: This may not work because Kubernetes does not automatically create directories for files with slashes in their names. The ConfigMap only includes top-level files from `kumo-configs/`.

## 🔗 References

- Lua require: https://www.lua.org/manual/5.4/manual.html#pdf-require
- Lua dofile: https://www.lua.org/manual/5.4/manual.html#pdf-dofile
- Kubernetes ConfigMap: https://kubernetes.io/docs/concepts/configuration/configmap/
