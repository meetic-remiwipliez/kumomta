--[[
  StirTalk Binding Group Configuration (Dallas)
  
  This module provides complete configuration for the StirTalk binding group:
  - Egress path configuration (binding group settings)
  - Routing logic to assign messages to StirTalk pool
  
  Note: Egress sources (bindings) are defined in sources.toml:
  - stir-talk-3: source_address = "10.10.25.47", ehlo_domain = "mx3.talk.stir.com"
  - stir-talk-5: source_address = "10.10.25.48", ehlo_domain = "mx5.talk.stir.com"
  
  Migration from Momentum:
  - Binding_Group → Pool (via sources.toml) + Egress Path (via kumo.make_egress_path)
  - Routing logic → Message inspection and metadata setting
]]

local kumo = require("kumo")

-- ============================================================================
-- PART 1: ROUTING LOGIC
-- ============================================================================
-- Function to check if a message should use StirTalk pool
-- This is called during http_message_generated to set metadata
-- Routing criteria (in priority order):
-- 1. Metadata "BindingGroup" = "StirTalk" (highest priority)
-- 2. X-Campaign-Data header with platform "SN" (Stir) and email type "Talk"
-- 3. X-Sender header containing "@talk.stir.com"
-- 4. MAIL FROM domain = "talk.stir.com"

local function should_use_stirtalk(msg)
  -- Priority 1: Check metadata "BindingGroup"
  local binding_group = msg:get_meta("BindingGroup")
  if binding_group == "StirTalk" then
    return true, "metadata_binding_group"
  end
  
  -- Priority 2: Check X-Campaign-Data header
  local x_campaign_data = msg:get_first_named_header_value("X-Campaign-Data")
  if x_campaign_data then
    if x_campaign_data:match("^SN%-.*Talk") or x_campaign_data:match("^SN%-Talk") then
      return true, "x_campaign_data"
    end
  end
  
  -- Priority 3: Check X-Sender header
  local x_sender = msg:get_first_named_header_value("X-Sender")
  if x_sender then
    if x_sender:match("@talk%.stir%.com") then
      return true, "x_sender"
    end
  end
  
  -- Priority 4: Check MAIL FROM domain
  -- In KumoMTA, msg:sender() returns an EnvelopeAddress object with a .domain property
  local sender = msg:sender()
  if sender then
    local mail_from_domain = sender.domain
    if mail_from_domain and mail_from_domain:lower() == "talk.stir.com" then
      return true, "mail_from"
    end
  end
  
  return false, nil
end

-- Export should_use_stirtalk function for use in init.lua
-- The handler http_message_generated will be registered in init.lua

-- ============================================================================
-- PART 2: EGRESS PATH CONFIGURATION (Binding Group)
-- ============================================================================
-- Handler function for get_egress_path_config
-- This function will be called by KumoMTA when determining egress path configuration
-- Returns domain-specific egress path configurations for StirTalk binding group

local function get_stirtalk_egress_path_config(domain, site_name, binding_group)
  -- Only process if this is for the StirTalk binding group
  if binding_group ~= "StirTalk" then
    return nil
  end

  -- Base configuration for all domains using StirTalk
  -- TLS = ifAvailable in Momentum maps to opportunistic TLS
  local base_config = {
    enable_tls = "Opportunistic",
    connection_limit = 32, -- Default Momentum Max_Outbound_Connections
    max_deliveries_per_connection = 100, -- Default Momentum Max_Recipients_Per_Connection
  }

  -- Domain-specific configurations
  -- These map directly from Momentum Domain blocks
  
  if domain == "gmail.com" then
    -- Domain "gmail.com" { TLS = required }
    return kumo.make_egress_path {
      enable_tls = "Required",
      connection_limit = base_config.connection_limit,
      max_deliveries_per_connection = base_config.max_deliveries_per_connection,
    }
  elseif domain == "hotmail.com" then
    -- Domain "hotmail.com" {
    --   Max_Outbound_Connections = 25
    --   Max_Recipients_Per_Connection = 100
    --   Outbound_Throttle_Messages = "1000/3600"
    -- }
    return kumo.make_egress_path {
      enable_tls = "Opportunistic",
      connection_limit = 25,
      max_deliveries_per_connection = 100,
      max_message_rate = "1000/3600",
    }
  elseif domain == "aol.com" then
    -- Domain "aol.com" {
    --   adaptive_max_deliveries_per_connection = (10 20)
    --   adaptive_max_outbound_connections = (10 100)
    -- }
    -- Note: Adaptive settings in Momentum are handled by Traffic Shaping Automation in KumoMTA
    return kumo.make_egress_path {
      enable_tls = "Opportunistic",
      connection_limit = 100, -- adaptive_max_outbound_connections upper bound
      max_deliveries_per_connection = 20, -- adaptive_max_deliveries_per_connection upper bound
    }
  elseif domain == "yahoo.com" then
    -- Domain "yahoo.com" {
    --   Max_Outbound_Connections = 25
    --   Max_Recipients_Per_Connection = 100
    --   Outbound_Throttle_Messages = "1000/3600"
    -- }
    return kumo.make_egress_path {
      enable_tls = "Opportunistic",
      connection_limit = 25,
      max_deliveries_per_connection = 100,
      max_message_rate = "1000/3600",
    }
  end

  -- Default configuration for other domains using StirTalk
  return kumo.make_egress_path(base_config)
end

-- Export functions for use in init.lua
return {
  should_use_stirtalk = should_use_stirtalk,
  get_egress_path_config = get_stirtalk_egress_path_config,
}
