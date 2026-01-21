# Migration Analysis: StirTalk Binding Group (Dallas)

## 📋 Executive Summary

This document describes the migration of the **StirTalk** binding group (Dallas) from Momentum/Ecelerity to KumoMTA.

**Scope**: StirTalk binding group configuration for Dallas only.  
**Date**: Initial migration  
**Status**: KumoMTA configuration created, ready for testing

---

## 🔍 Momentum Configuration Analysis

### Source Configuration

**File**: `configuration_momentum/default/includes/binding_groups/StirTalk`

#### Binding Group Structure

```
Binding_Group "StirTalk" {
  Enable_FBL_Header_Insertion = enabled
  TLS = ifAvailable
  TLS_Certificate = "/home/ecuser_certs/certs/talk.stir.com-tls.crt"
  TLS_Key = "/home/ecuser_certs/certs/talk.stir.com-tls.key"

  Domain "gmail.com" {
    TLS = required
  }
  Domain "hotmail.com" {
    Max_Outbound_Connections = 25
    Max_Recipients_Per_Connection = 100
    Outbound_Throttle_Messages = "1000/3600"
  }
  Domain "aol.com" {
    adaptive_max_deliveries_per_connection = (10 20)
    adaptive_max_outbound_connections = (10 100)
  }
  Domain "yahoo.com" {
    Max_Outbound_Connections = 25
    Max_Recipients_Per_Connection = 100
    Outbound_Throttle_Messages = "1000/3600"
  }

  Binding StirTalk3 {
    Bind_Address = "10.10.25.47"
    Duravip_Preference = "da3shml024.iacp.dc"
    EHLO_Hostname = "mx3.talk.stir.com"
    enable_duravip = "true"
    include "/opt/msys/ecelerity/etc/conf/global/delivery_domains.d"
  }

  Binding StirTalk5 {
    Bind_Address = "10.10.25.48"
    Duravip_Preference = "da3shml024.iacp.dc"
    EHLO_Hostname = "mx5.talk.stir.com"
    enable_duravip = "true"
  }
}
```

#### Associated Listeners

**mx3.talk.stir.com**:
- Listen `10.10.25.47:25` (SMTP)
- Listen `10.10.25.47:587` (Submission)
- Site: DALLAS
- Private IP: 10.10.25.47
- Public IP: (not defined in comments)

**mx5.talk.stir.com**:
- Listen `10.10.25.48:25` (SMTP)
- Listen `10.10.25.48:587` (Submission)
- Site: DALLAS
- Private IP: 10.10.25.48
- Public IP: (not defined in comments)

---

## ⚠️ Inconsistencies in Momentum Configuration

The following items were identified as potentially problematic in the Momentum source. **These are documented but NOT fixed** in the final KumoMTA configuration, as requested.

### 1. Inconsistent delivery_domains.d Inclusion

**Issue**:
- Binding `StirTalk3` includes `"/opt/msys/ecelerity/etc/conf/global/delivery_domains.d"`
- Binding `StirTalk5` does NOT include this directive

**Impact**: The two bindings in the same binding group may behave differently for delivery domains.

**Action**: Documented only, not changed in KumoMTA.

### 2. Public IPs Not Defined

**Issue**:
- Comments in listener files show `Public IP:` with no value
- Momentum bindings use only private IPs (10.10.25.47 and 10.10.25.48)

**Impact**: Uncertainty about the actual public IPs used for outbound sending.

**Action**: Documented only. KumoMTA configuration uses the same private IPs as Momentum.

### 3. Duravip_Preference Not Mapped

**Issue**:
- Momentum bindings set `Duravip_Preference = "da3shml024.iacp.dc"`
- `enable_duravip = "true"` is also set
- "Duravip" is Momentum-specific and has no equivalent in KumoMTA

**Impact**: Duravip preference logic is not migrated. KumoMTA uses a different source-selection model.

**Action**: Documented only. KumoMTA configuration defines sources without Duravip logic.

### 4. Enable_FBL_Header_Insertion Not Migrated

**Issue**:
- The Momentum binding group sets `Enable_FBL_Header_Insertion = enabled`
- This is not migrated in the initial KumoMTA configuration

**Impact**: FBL headers will not be inserted automatically.

**Action**: Documented only. To be migrated in a later phase if required.

### 5. TLS Certificates Not Migrated

**Issue**:
- TLS certificates are defined at the binding group level:
  - `TLS_Certificate = "/home/ecuser_certs/certs/talk.stir.com-tls.crt"`
  - `TLS_Key = "/home/ecuser_certs/certs/talk.stir.com-tls.key"`
- These paths are not configured in KumoMTA

**Impact**: TLS certificates must be configured separately in KumoMTA (e.g. via Kubernetes secrets/mounts).

**Action**: Documented only. Certificates must be mounted into the KumoMTA container.

---

## 🔄 Momentum → KumoMTA Mapping

### General Concepts

| Momentum | KumoMTA | Notes |
|----------|---------|-------|
| `Binding` | `Egress Source` | Via `kumo.make_egress_source()` or `sources.toml` |
| `Binding_Group` | `Pool` | Via `sources.toml` and Lua handlers |
| `Bind_Address` | `source_address` | Source IP for outbound connections |
| `EHLO_Hostname` | `ehlo_domain` | Domain in EHLO |
| `TLS = ifAvailable` | `enable_tls = "Opportunistic"` | Opportunistic TLS |
| `TLS = required` | `enable_tls = "Required"` | Required TLS |
| `Max_Outbound_Connections` | `connection_limit` | Concurrent connection limit |
| `Max_Recipients_Per_Connection` | `max_deliveries_per_connection` | Messages per connection |
| `Outbound_Throttle_Messages` | `max_message_rate` | Message throttling |

### StirTalk-Specific Mapping

#### Bindings → Sources

**StirTalk3**:
- Momentum: `Bind_Address = "10.10.25.47"`, `EHLO_Hostname = "mx3.talk.stir.com"`
- KumoMTA: Source `stir-talk-3` in `sources.toml` (ehlo_domain; source_address optional, uses Pod IP if not set)

**StirTalk5**:
- Momentum: `Bind_Address = "10.10.25.48"`, `EHLO_Hostname = "mx5.talk.stir.com"`
- KumoMTA: Source `stir-talk-5` in `sources.toml` (ehlo_domain; source_address optional, uses Pod IP if not set)

#### Binding Group → Pool

**StirTalk**:
- Momentum: `Binding_Group "StirTalk"`
- KumoMTA: Pool `StirTalk` in `sources.toml` with sources `stir-talk-3` and `stir-talk-5`

#### Domain-Specific Configurations

Domain rules are implemented in the `get_egress_path_config` handler in `stir_talk.lua`:

- **gmail.com**: TLS = Required
- **hotmail.com**: connection_limit = 25, max_deliveries_per_connection = 100, max_message_rate = "1000/3600"
- **aol.com**: connection_limit = 100, max_deliveries_per_connection = 20 (upper adaptive values)
- **yahoo.com**: connection_limit = 25, max_deliveries_per_connection = 100, max_message_rate = "1000/3600"

---

## 📁 Created File Structure

### KumoMTA Files

```
kumomta-k8s-demo/charts/kumomta/kumo-configs/
├── stir_talk.lua               # Routing (should_use_stirtalk) + egress path (get_egress_path_config)
├── sources.toml                # StirTalk pool and sources (stir-talk-3, stir-talk-5)
└── init.lua                    # Entry point (loads stir_talk.lua, wires handlers)
```

### File Descriptions

#### `stir_talk.lua`

- **Routing**: `should_use_stirtalk(msg)` — determines if a message uses the StirTalk pool (called from `process_message()` in init.lua).
- **Egress path**: `get_egress_path_config(domain, site_name, binding_group)` — domain-specific rules (TLS, connection_limit, max_message_rate) for the StirTalk binding group.

#### `sources.toml`

Defines the StirTalk sources (`stir-talk-3`, `stir-talk-5`) and pool. Source IPs are optional in Kubernetes (Pod IP used if not set).

#### `init.lua` (modified)

Loads the StirTalk module and wires it into the processing flow.

**Changes**:
- `dofile("/opt/kumomta/etc/policy/stir_talk.lua")` before `sources:setup()`
- `get_egress_path_config`: call `stir_talk.get_egress_path_config` first, then fall back to shaper
- `process_message()`: call `stir_talk.should_use_stirtalk()` before `queue_helper:apply()`

---

## ✅ Validation Checklist

### Configuration Complete

- [x] Sources defined (stir-talk-3, stir-talk-5)
- [x] Pool created (StirTalk)
- [x] Domain rules configured (gmail.com, hotmail.com, aol.com, yahoo.com)
- [x] TLS configured (Opportunistic by default, Required for gmail.com)
- [x] Throttling configured (hotmail.com, yahoo.com)
- [x] Modules loaded in init.lua

### To Validate in Production

- [ ] IPs 10.10.25.47 and 10.10.25.48 are available in Kubernetes
- [ ] TLS certificates are mounted in the container
- [ ] StirTalk binding group is correctly assigned to messages (via routing/policy)
- [ ] Domain rules behave as expected
- [ ] Throttling is applied as intended

---

## 📝 Migration Notes

### Intentionally Not Migrated

1. **Duravip**: Momentum-specific, not applicable in KumoMTA
2. **Enable_FBL_Header_Insertion**: To be migrated in a later phase if needed
3. **include delivery_domains.d**: Momentum-specific logic, not migrated

### Required Adaptations

1. **Adaptive settings (aol.com)**: Momentum’s adaptive values are migrated using the upper values. Dynamic adaptation can be implemented via KumoMTA Traffic Shaping Automation (TSA) if needed.

2. **TLS certificates**: Must be mounted in the Kubernetes container via secrets/configmaps. Paths in KumoMTA may differ from Momentum.

3. **Routing**: Binding group assignment is out of scope for this migration. It must be configured separately (Lua policy or routing config).

---

## 🔗 References

- KumoMTA: https://docs.kumomta.com/
- Momentum → KumoMTA: https://kumomta.com/blog/moving-from-momentum
- Config conversion: https://kumomta.com/blog/easy-config-conversions
- KumoMTA concepts: https://docs.kumomta.com/userguide/configuration/concepts/
- Policy helpers: https://docs.kumomta.com/userguide/configuration/policy_helpers/
