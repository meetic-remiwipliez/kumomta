# StirTalk Routing/Policy Configuration

## 📋 Overview

This document describes the routing/policy configuration for assigning messages to the **StirTalk** pool in KumoMTA.

## 🔄 Momentum → KumoMTA Mapping

In Momentum, routing is done via:
- `validate_set_binding.lua` (Momentum script in `configuration_momentum/global/mtch/`, not in KumoMTA) which assigns binding groups via database queries
- Context variables `BindingGroup` or `Binding`
- Headers (X-Campaign-Data, X-Sender)
- IPs (listener IP, sending IP)
- Domains (MAIL FROM)

In KumoMTA, routing is done via:
- `http_message_generated` handler to analyze the message and set metadata
- `get_queue_config` handler to assign the egress pool
- `queues.toml` configuration to define tenants and their pools

## 📁 Created/Modified Files

### 1. `stir_talk.lua`

Routing module (at `kumo-configs/stir_talk.lua`) that:
- Analyzes messages in `http_message_generated`
- Determines whether a message should use the StirTalk pool
- Sets the `X-Tenant: StirTalk` header for appropriate messages

**Routing criteria (in order of priority)**:
1. Metadata `BindingGroup` = "StirTalk"
2. Header `X-Campaign-Data` with platform "SN" (Stir) and email type "Talk"
3. Header `X-Sender` containing "@talk.stir.com"
4. MAIL FROM domain = "talk.stir.com"

### 2. `init.lua` (modified)

- Loads the StirTalk routing module
- Adds a `get_queue_config` handler to assign the StirTalk pool

### 3. `queues.toml` (modified)

- Adds the `StirTalk` tenant configuration with `egress_pool = 'StirTalk'`

## 🔧 How It Works

### Processing Flow

1. **Message received** (`http_message_generated`)
   - The `stir_talk.lua` handler analyzes the message
   - If the criteria are met, it sets:
     - `msg:set_meta("binding_group", "StirTalk")`
     - `msg:prepend_header("X-Tenant", "StirTalk")`

2. **Queue configuration** (`get_queue_config`)
   - The handler in `init.lua` checks if `tenant == "StirTalk"`
   - If yes, returns `kumo.make_queue_config { egress_pool = "StirTalk" }`
   - Otherwise returns `nil` to use the default configuration

3. **Queue application** (`queue_helper:apply`)
   - The queue_helper reads the tenant from `X-Tenant`
   - Uses the configuration from `queues.toml` or `get_queue_config`
   - Assigns the message to the appropriate pool

## 📝 Usage Examples

### Via X-Tenant header

```http
POST /api/v1/inject
X-Tenant: StirTalk
...
```

### Via BindingGroup metadata

The message must have the `BindingGroup` metadata set to "StirTalk" (e.g. via an external system).

### Via X-Campaign-Data

```http
X-Campaign-Data: SN-Talk-12345-...
```

### Via X-Sender

```http
X-Sender: sender@talk.stir.com
```

### Via MAIL FROM

```
MAIL FROM: <sender@talk.stir.com>
```

## ⚠️ Important Notes

1. **Handler order**: In `init.lua`, `process_message()` calls `stir_talk.should_use_stirtalk()` before `queue_helper:apply()`. This ensures routing is applied before queue assignment.

2. **Listener IP**: Listener IP checking is not implemented because KumoMTA does not expose this directly in `http_message_generated`. If needed, this can be added via other mechanisms (e.g. a proxy or custom header).

3. **Database**: Database-based routing (as in Momentum) is not migrated. If needed, it can be added using KumoMTA datasources.

4. **Compatibility**: The configuration is compatible with the existing queue system and does not affect other binding groups.

## 🧪 Recommended Tests

1. **Test with X-Tenant header**:
   ```bash
   curl -X POST http://kumomta:8000/api/v1/inject \
     -H "X-Tenant: StirTalk" \
     -d @message.json
   ```

2. **Test with X-Campaign-Data**:
   ```bash
   curl -X POST http://kumomta:8000/api/v1/inject \
     -H "X-Campaign-Data: SN-Talk-12345" \
     -d @message.json
   ```

3. **Check logs**:
   - Look for "StirTalk routing: Assigned message to StirTalk pool"
   - Confirm the pool used is "StirTalk"

4. **Verify configuration**:
   - Ensure `queues.toml` contains `[tenant.'StirTalk']`
   - Ensure `sources.toml` contains the `StirTalk` pool
