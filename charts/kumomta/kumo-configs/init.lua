-- example config:
-- https://docs.kumomta.com/userguide/configuration/example/
--

local kumo = require("kumo")
local utils = require("policy-extras.policy_utils")

-- Unused policy helpers
-- local listener_domains = require 'policy-extras.listener_domains'
-- local log_hooks = require 'policy-extras.log_hooks'

-- Load StirTalk configuration (Dallas)
-- The file contains: routing logic and egress path configuration
-- Note: Egress sources are defined in sources.toml
local stir_talk = dofile("/opt/kumomta/etc/policy/stir_talk.lua")

-- START SETUP
--
-- Configure the sending IP addresses that will be used by KumoMTA to
-- connect to remote systems using the sources.lua policy helper.
-- NOTE that defining sources and pools does nothing without some form of
-- policy in effect to assign messages to the source pools you have defined.
-- SEE https://docs.kumomta.com/userguide/configuration/sendingips/
local sources = require("policy-extras.sources")
sources:setup({ "/opt/kumomta/etc/policy/sources.toml" })

-- Note: In Kubernetes, source_address is not specified in sources.toml
-- KumoMTA will automatically use the Pod IP for all egress sources
-- This is the recommended approach per https://kumomta.com/blog/moving-from-momentum
-- If you need specific IPs, configure them at the network level (hostNetwork, external IPs, etc.)

-- Handler for queue configuration
-- CRITICAL: This handler MUST be registered BEFORE queue_helper:setup() is called
-- Handlers are called in registration order, so this ensures our sink routing
-- takes precedence over queue_helper's configuration from queues.toml
kumo.on("get_queue_config", function(domain, tenant, campaign, routing_domain)
  local sink_enabled = os.getenv("KUMOMTA_SINK_ENABLED") == "true"
  local sink_ip = os.getenv("KUMOMTA_SINK_IP")
  local sink_endpoint = os.getenv("KUMOMTA_SINK_ENDPOINT") or "kumomta-sink.kumomta.svc.cluster.local"
  
  -- Debug logging - ALWAYS log to verify handler is called
  kumo.log_info(string.format(
    "[SINK] get_queue_config called: domain=%s, tenant=%s, campaign=%s, routing_domain=%s, sink_enabled=%s",
    domain or "nil", tenant or "nil", campaign or "nil", routing_domain or "nil", tostring(sink_enabled)
  ))
  
  -- If sink is enabled, route ALL queues to the sink service
  -- This MUST return a config to prevent queue_helper from overriding it
  if sink_enabled then
    -- Use the service DNS name - Kubernetes will resolve it automatically
    -- The service name will be resolved to the ClusterIP by Kubernetes DNS
    -- Format: [IP] is only needed if we want to bypass DNS, but we want DNS resolution
    local sink_target = sink_endpoint
    
    -- If an explicit IP is provided, use it in brackets format to bypass DNS
    -- Otherwise, use the service DNS name which will be resolved by Kubernetes
    if sink_ip and sink_ip ~= "" then
      sink_target = "[" .. sink_ip .. "]"
      kumo.log_info(string.format("[SINK] Using explicit sink IP: %s", sink_target))
    else
      kumo.log_info(string.format("[SINK] Using sink service DNS name (will be resolved by Kubernetes): %s", sink_target))
    end
    
    -- Build config with sink routing
    local config = {
      protocol = {
        smtp = {
          mx_list = { sink_target },
        },
      },
    }
    
    -- Preserve egress_pool if tenant is StirTalk
    if tenant == "StirTalk" then
      config.egress_pool = "StirTalk"
    end
    
    kumo.log_info(string.format(
      "[SINK] Routing queue for domain=%s, tenant=%s to sink=%s",
      domain or "nil", tenant or "nil", sink_target
    ))
    
    -- Return config to stop handler chain - this prevents queue_helper from overriding
    return kumo.make_queue_config(config)
  end
  
  -- If sink is not enabled, return an empty config to let queue_helper use queues.toml configuration
  -- This allows KumoMTA to automatically resolve MX records for the destination domain
  -- NOTE: We must return a valid QueueConfig, not nil, to avoid "error converting Lua nil to QueueConfig"
  kumo.log_info(string.format(
    "[ROUTING] Sink disabled - Using queue_helper configuration for domain=%s, tenant=%s, campaign=%s, routing_domain=%s | MX resolution will be performed automatically",
    domain or "nil", tenant or "nil", campaign or "nil", routing_domain or "nil"
  ))
  
  -- Return empty config to allow queue_helper to use queues.toml configuration
  -- This enables automatic MX resolution for the destination domain
  -- The empty config will use default values, and queue_helper will apply settings from queues.toml
  return kumo.make_queue_config({})
end)

-- Configure DKIM signing. In this case we use the dkim_sign.lua policy helper.
-- WARNING: THIS WILL NOT LOAD WITHOUT the dkim_data.toml FILE IN PLACE
-- See https://docs.kumomta.com/userguide/configuration/dkim/
-- Load base DKIM configuration and domain-specific configurations
local dkim_sign = require("policy-extras.dkim_sign")
local dkim_signer = dkim_sign:setup({
  "/opt/kumomta/etc/policy/dkim_data.toml",
  "/opt/kumomta/etc/policy/dkim_talk.stir.com.toml",
})

-- Load Traffic Shaping Automation Helper
local shaping = require("policy-extras.shaping")
local shaper = shaping:setup_with_automation({
	-- see https://github.com/KumoCorp/kumomta/commit/3b61f1b92c5a416e81945432fefa2232617648f8 for pre filter details
	pre_filter = true,
	publish = kumo.string.split(os.getenv("KUMOMTA_TSA_PUBLISH_HOST") or "http://kumomta-tsa:8008", ","),
	subscribe = kumo.string.split(os.getenv("KUMOMTA_TSA_SUBSCRIBE_HOST") or "http://kumomta-tsa:8008", ","),
	extra_files = { "/opt/kumomta/etc/policy/shaping.toml" },
})

-- Configure queue management settings. These are not throttles, but instead
-- control how messages flow through the queues.
-- WARNING: ENSURE THAT WEBHOOKS AND SHAPING ARE SETUP BEFORE THE QUEUE HELPER FOR PROPER OPERATION
-- WARNING: THIS WILL NOT LOAD WITHOUT the queues.toml FILE IN PLACE
-- See https://docs.kumomta.com/userguide/configuration/queuemanagement/
local queue_module = require("policy-extras.queue")
local queue_helper = queue_module:setup({ "/opt/kumomta/etc/policy/queues.toml" })

-- END SETUP

-- START EVENT HANDLERS
--
-- Called On Startup, handles initial configuration
kumo.on("init", function()
	-- Define the default "data" spool location; this is where
	-- message bodies will be stored.
	-- See https://docs.kumomta.com/userguide/configuration/spool/
	kumo.define_spool({
		name = "data",
		path = "/var/spool/kumomta/data",
		kind = "RocksDB",
	})

	-- Define the default "meta" spool location; this is where
	-- message envelope and metadata will be stored.
	kumo.define_spool({
		name = "meta",
		path = "/var/spool/kumomta/meta",
		kind = "RocksDB",
	})
	kumo.set_spoolin_threads(os.getenv("KUMOMTA_SPOOLIN_THREADS") or 8)
	kumo.set_httpinject_threads(os.getenv("KUMOMTA_HTTPIN_THREADS") or 8)

	-- Use shared throttles and connection limits rather than in-process throttles
	-- TODO: consider implementing auth on redis
	if os.getenv("KUMOMTA_REDIS_CLUSTER_MODE") == "true" then
		REDIS_CLUSTER_MODE = true
	end
	kumo.configure_redis_throttles({
		node = os.getenv("KUMOMTA_REDIS_HOST") or "redis://kumomta-redis",
		cluster = REDIS_CLUSTER_MODE,
		pool_size = os.getenv("KUMOMTA_REDIS_POOL_SIZE") or 100,
		read_from_replicas = os.getenv("KUMOMTA_REDIS_READ_FROM_REPLICAS") or true,
		username = os.getenv("KUMOMTA_REDIS_USERNAME") or nil,
		password = os.getenv("KUMOMTA_REDIS_PASSWORD") or nil,
	})
	-- Configure logging to local disk. Separating spool and logs to separate
	-- disks helps reduce IO load and can help performance.
	-- See https://docs.kumomta.com/userguide/configuration/logging/
	-- Configure per-record logging to also log delivery/bounce events
	-- Note: These logs are written to files in /var/log/kumomta
	-- To see them in stdout, check the log files or use the diagnostic logs
	kumo.configure_local_logs({
		log_dir = "/var/log/kumomta",
		max_segment_duration = "1 minute",
		per_record = {
			Delivery = {
				-- Log delivery events with detailed information
				template = "[DELIVERY] Message delivered - ID: {{ id }} | From: {{ sender }} | To: {{ recipient }} | Queue: {{ queue }} | Code: {{ response.code }} | Reason: {{ response.content }}",
			},
			Bounce = {
				-- Log bounce events with detailed information
				template = "[BOUNCE] Permanent failure - ID: {{ id }} | From: {{ sender }} | To: {{ recipient }} | Queue: {{ queue }} | Code: {{ response.code }} | Reason: {{ response.content }} | Class: {{ bounce_classification }}",
			},
			TransientFailure = {
				-- Log transient failure events
				template = "[TRANSIENT_FAILURE] Temporary failure - ID: {{ id }} | From: {{ sender }} | To: {{ recipient }} | Queue: {{ queue }} | Code: {{ response.code }} | Reason: {{ response.content }}",
			},
			Expiration = {
				-- Log expiration events
				template = "[EXPIRATION] Message expired - ID: {{ id }} | From: {{ sender }} | To: {{ recipient }} | Queue: {{ queue }}",
			},
		},
	})
	
	-- Configure a log hook to also write delivery/bounce events to stdout
	-- This creates a custom log hook that writes to stdout via kumo.log_info
	kumo.configure_log_hook({
		name = "stdout_logger",
		headers = { "Subject", "Message-ID" },
	})
	
	-- Enable debug logging for all components
	-- This sets diagnostic log filters for detailed debugging
	-- Can be overridden by KUMOD_LOG environment variable
	-- dns=debug enables MX resolution logging
	-- egress=debug enables outbound SMTP connection logging
	-- smtp=debug enables SMTP protocol logging
	kumo.set_diagnostic_log_filter("kumod=debug,lua=debug,http=debug,smtp=debug,queue=debug,egress=debug,redis=debug,dns=debug")
	-- configure smtp listener
	kumo.start_esmtp_listener({
		listen = "0.0.0.0:2500",
		relay_hosts = { "0.0.0.0/0" },
	})

	-- Configure HTTP Listeners for injection and management APIs.
	-- See https://docs.kumomta.com/userguide/configuration/httplisteners/
	kumo.start_http_listener({
		listen = "0.0.0.0:8000",
		trusted_hosts = kumo.string.split(os.getenv("KUMOMTA_TRUSTED_HOSTS") or "0.0.0.0", ","),
		-- trusted_hosts = trusted_hosts_table,
	})

	-- Configure bounce classification.
	-- See https://docs.kumomta.com/userguide/configuration/bounce/
	kumo.configure_bounce_classifier({
		files = {
			"/opt/kumomta/share/bounce_classifier/iana.toml",
		},
	})
	shaper.setup_publish()
end)

-- Call the Traffic Shaping Automation Helper to configure shaping rules.
-- The StirTalk handler will be called first, then fall back to shaper if needed
kumo.on("get_egress_path_config", function(domain, site_name, binding_group)
  -- Log egress path configuration request
  kumo.log_info(string.format(
    "[EGRESS] get_egress_path_config called - Domain: %s | Site: %s | BindingGroup: %s | MX resolution will be performed for this domain",
    domain or "nil", site_name or "nil", binding_group or "nil"
  ))
  
  -- Try StirTalk handler first
  local result = stir_talk.get_egress_path_config(domain, site_name, binding_group)
  if result then
    kumo.log_info(string.format(
      "[EGRESS] Using StirTalk egress path config for domain=%s, binding_group=%s",
      domain or "nil", binding_group or "nil"
    ))
    return result
  end
  
  -- Fall back to shaper for other binding groups
  local shaper_result = shaper.get_egress_path_config(domain, site_name, binding_group)
  if shaper_result then
    kumo.log_info(string.format(
      "[EGRESS] Using shaper egress path config for domain=%s, binding_group=%s",
      domain or "nil", binding_group or "nil"
    ))
  end
  return shaper_result
end)

-- ============================================================================
-- COMMON MESSAGE PROCESSING FUNCTION
-- ============================================================================
-- This function processes messages received via HTTP or SMTP
-- It applies StirTalk routing, queue configuration, sink mode, and DKIM signing
local function process_message(msg)
	-- Apply StirTalk routing logic before queue_helper
	-- This sets metadata/headers that queue_helper will use
	local use_stirtalk, reason = stir_talk.should_use_stirtalk(msg)
	if use_stirtalk then
		-- Set metadata to indicate this message should use StirTalk pool
		msg:set_meta("binding_group", "StirTalk")
		
		-- Set tenant to StirTalk for queue routing
		if not msg:get_first_named_header_value("X-Tenant") then
			msg:prepend_header("X-Tenant", "StirTalk")
		end
		
		-- Log the assignment (optional, for debugging)
		-- kumo.log_info is available in KumoMTA 2025.03.19+
		kumo.log_info(string.format(
			"StirTalk routing: Assigned message to StirTalk pool (reason: %s)",
			reason or "unknown"
		))
	end

	queue_helper:apply(msg)
	
	-- Log queue assignment after queue_helper:apply
	local queue_name = msg:get_meta("queue") or "unknown"
	local routing_domain = msg:get_meta("routing_domain") or "unknown"
	
	-- Get sender - msg:sender() returns EnvelopeAddress object
	local sender_str = "unknown"
	local sender_obj = msg:sender()
	if sender_obj then
		sender_str = tostring(sender_obj)
	end
	
	-- Get recipients - try recipient(0) first, then fallback to To header
	local recipients = {}
	local recipient = msg:recipient(0)
	if recipient then
		table.insert(recipients, tostring(recipient))
	else
		-- Fallback: try to get from To header
		local to_header = msg:to_header()
		if to_header then
			if type(to_header) == "table" then
				for _, addr in ipairs(to_header) do
					if addr and addr ~= "" then
						table.insert(recipients, tostring(addr))
					end
				end
			elseif type(to_header) == "string" then
				for addr in tostring(to_header):gmatch("[%w%._%-]+@[%w%._%-]+") do
					table.insert(recipients, addr)
				end
			end
		end
	end
	local recipient_str = table.concat(recipients, ", ")
	if recipient_str == "" then
		recipient_str = "unknown"
	end
	
	-- Extract domain from recipient for logging
	local recipient_domain = "unknown"
	if recipient_str ~= "unknown" and recipient_str ~= "" then
		local domain_match = recipient_str:match("@(.+)$")
		if domain_match then
			recipient_domain = domain_match
		end
	end
	
	kumo.log_info(string.format(
		"[ROUTING] Message queued - From: %s | To: %s | Domain: %s | Queue: %s | RoutingDomain: %s | BindingGroup: %s | Message will be delivered via MX resolution",
		sender_str, recipient_str, recipient_domain, queue_name, routing_domain, msg:get_meta("binding_group") or "unknown"
	))
	
	-- Note: Sink routing is handled in get_queue_config, not via routing_domain
	-- This allows MX resolution to happen normally on recipient domain,
	-- then all queues are routed to sink via mx_list configuration
	-- SIGNING MUST COME LAST OR YOU COULD BREAK YOUR DKIM SIGNATURES
	dkim_signer(msg)
end

-- Processing of incoming messages via HTTP
kumo.on("http_message_generated", function(msg)
	-- TM:1 Aug 2024 - added this to ensure Massage ID is added:
	local failed = msg:check_fix_conformance(
		-- check for and reject messages with these issues:
		"MISSING_COLON_VALUE",
		-- fix messages with these issues:
		"LINE_TOO_LONG|NAME_ENDS_WITH_SPACE|NEEDS_TRANSFER_ENCODING|NON_CANONICAL_LINE_ENDINGS|MISSING_DATE_HEADER|MISSING_MESSAGE_ID_HEADER|MISSING_MIME_VERSION"
	)
	if failed then
		kumo.reject(552, string.format("5.6.0 %s", failed))
	end

	process_message(msg)
end)

-- Processing of incoming messages via SMTP
-- This handler is called when messages are received via the SMTP listener
kumo.on("smtp_server_message_received", function(msg)
	process_message(msg)
end)

-- Use this to lookup and confirm a user/password credential for http api
kumo.on("http_server_validate_auth_basic", function(user, password)
	return cached_get_auth(user, password)
end)

-- Handler to log SMTP delivery responses to stdout
-- This intercepts SMTP server responses and logs them for visibility
kumo.on("smtp_client_rewrite_delivery_status", function(response, domain, tenant, campaign, routing_domain)
	-- Log the SMTP server response for visibility
	-- response is a string containing the full SMTP response (e.g., "250 2.0.0 OK" or "550 5.1.1 User unknown")
	kumo.log_info(string.format(
		"[SMTP_RESPONSE] Domain: %s | Tenant: %s | Campaign: %s | RoutingDomain: %s | Response: %s",
		domain or "nil", tenant or "nil", campaign or "nil", routing_domain or "nil", response or "nil"
	))
	
	-- Return nil to keep the original response unchanged
	return nil
end)

-- Handler to log when messages are ready to be delivered
-- This helps track if messages are being processed for delivery
kumo.on("throttle_insert_ready_queue", function(msg)
	local queue_name = msg:queue_name() or "unknown"
	local sender = "unknown"
	local sender_obj = msg:sender()
	if sender_obj then
		sender = tostring(sender_obj)
	end
	local recipient = "unknown"
	local recipient_obj = msg:recipient(0)
	if recipient_obj then
		recipient = tostring(recipient_obj)
	end
	local num_attempts = msg:num_attempts() or 0
	
	kumo.log_info(string.format(
		"[READY_QUEUE] Message ready for delivery attempt #%d - From: %s | To: %s | Queue: %s",
		num_attempts, sender, recipient, queue_name
	))
end)

-- Handler to log when messages are being requeued
-- This helps track delivery attempts and retries
kumo.on("requeue_message", function(msg)
	local queue_name = msg:queue_name() or "unknown"
	local sender = "unknown"
	local sender_obj = msg:sender()
	if sender_obj then
		sender = tostring(sender_obj)
	end
	local recipient = "unknown"
	local recipient_obj = msg:recipient(0)
	if recipient_obj then
		recipient = tostring(recipient_obj)
	end
	local num_attempts = msg:num_attempts() or 0
	
	kumo.log_info(string.format(
		"[REQUEUE] Message requeued for delivery attempt #%d - From: %s | To: %s | Queue: %s",
		num_attempts, sender, recipient, queue_name
	))
end)

-- Handler to log delivery/bounce events from the stdout_logger hook
-- This intercepts log records destined for the stdout_logger hook and logs them to stdout
kumo.on("should_enqueue_log_record", function(msg, hook_name)
	-- Only process log records for the stdout_logger hook
	if hook_name == "stdout_logger" then
		local log_record = msg:get_meta("log_record")
		if log_record then
			local record_type = log_record.type or log_record.kind
			local msg_id = log_record.id or "unknown"
			local sender = log_record.sender or "unknown"
			local recipient = log_record.recipient or "unknown"
			local queue = log_record.queue or "unknown"
			
			-- Log delivery events
			if record_type == "Delivery" then
				local response = log_record.response or {}
				local code = response.code or "unknown"
				local reason = response.content or response.reason or "unknown"
				kumo.log_info(string.format(
					"[DELIVERY] ✓ Message delivered - ID: %s | From: %s | To: %s | Queue: %s | Code: %s | Reason: %s",
					msg_id, sender, recipient, queue, tostring(code), tostring(reason)
				))
			-- Log bounce events (permanent failures)
			elseif record_type == "Bounce" then
				local response = log_record.response or {}
				local code = response.code or "unknown"
				local reason = response.content or response.reason or "unknown"
				local bounce_class = log_record.bounce_classification or log_record.bounce_class or "unknown"
				kumo.log_info(string.format(
					"[BOUNCE] ✗ Permanent failure - ID: %s | From: %s | To: %s | Queue: %s | Code: %s | Reason: %s | Class: %s",
					msg_id, sender, recipient, queue, tostring(code), tostring(reason), tostring(bounce_class)
				))
			-- Log transient failure events
			elseif record_type == "TransientFailure" then
				local response = log_record.response or {}
				local code = response.code or "unknown"
				local reason = response.content or response.reason or "unknown"
				kumo.log_info(string.format(
					"[TRANSIENT_FAILURE] ⚠ Temporary failure - ID: %s | From: %s | To: %s | Queue: %s | Code: %s | Reason: %s",
					msg_id, sender, recipient, queue, tostring(code), tostring(reason)
				))
			-- Log expiration events
			elseif record_type == "Expiration" then
				kumo.log_info(string.format(
					"[EXPIRATION] ⏱ Message expired - ID: %s | From: %s | To: %s | Queue: %s",
					msg_id, sender, recipient, queue
				))
			end
		end
		-- Set queue to null to prevent actual delivery of the log record
		msg:set_meta("queue", "null")
		return false
	end
	
	-- Return true to allow other log records to be enqueued normally
	return true
end)

-- Note: Delivery/bounce events are also logged via kumo.configure_local_logs templates above
-- The templates will write to log files in /var/log/kumomta
-- To see these logs in kubectl logs, you can tail the log files or use a sidecar
-- The diagnostic logs (kumo.set_diagnostic_log_filter) will also show egress/debug information
-- END EVENT HANDLERS

-- START UTILITY FUNCTIONS
--
-- NOTE: k8s secret should be mounted to "/opt/kumomta/etc/http_listener_keys/"
-- Secret keys should be user names, values should be password.
-- Example:
-- data:
--   userName: <some secret generated using `openssl rand -hex 16`>
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

cached_get_auth = kumo.memoize(get_auth, {
	name = "get_auth",
	ttl = "5 minutes",
	capacity = 2,
})

function auth_file_exists(file)
	local f = io.open(file, "r")
	if f then
		f:close()
	end
	return f ~= nil
end

cached_auth_file_exists = kumo.memoize(auth_file_exists, {
	name = "auth_file_exists",
	ttl = "1 minute",
	capacity = 2,
})

-- END UTILITY FUNCTIONS
