--[[
###############################################################################
# KumoMTA Policy Configuration for example.com
###############################################################################
# 
# This configuration file defines the policy for KumoMTA deployment on
# Kubernetes, specifically configured for the domain: example.com
#
# Architecture:
# - StatefulSet for MTA pods with persistent queues
# - TSA (Traffic Shaping Automation) for dynamic shaping
# - Redis for shared throttles
# - DKIM signing with keys from Kubernetes Secrets
#
# Documentation:
# - https://docs.kumomta.com/userguide/configuration/concepts/
# - https://docs.kumomta.com/reference/
###############################################################################
]]

local kumo = require("kumo")
local utils = require("policy-extras.policy_utils")

--[[
###############################################################################
# CONFIGURATION SETUP
###############################################################################
# Load and configure policy helpers in the correct order:
# 1. Sources (IP pools)
# 2. DKIM signing
# 3. Traffic shaping automation
# 4. Queue management
###############################################################################
]]

--[[
# SOURCES CONFIGURATION
# Configure the sending IP addresses that will be used by KumoMTA to
# connect to remote systems using the sources.lua policy helper.
# NOTE: Defining sources and pools does nothing without some form of
# policy in effect to assign messages to the source pools you have defined.
# See: https://docs.kumomta.com/userguide/configuration/sendingips/
]]
local sources = require("policy-extras.sources")
sources:setup({ "/opt/kumomta/etc/policy/sources.toml" })

--[[
# DKIM SIGNING CONFIGURATION
# Configure DKIM signing using the dkim_sign.lua policy helper.
# WARNING: This requires the dkim_data.toml file to be in place.
# DKIM keys are loaded from Kubernetes Secrets mounted at:
# /opt/kumomta/etc/policy/dkim/
# See: https://docs.kumomta.com/userguide/configuration/dkim/
]]
local dkim_sign = require("policy-extras.dkim_sign")
local dkim_signer = dkim_sign:setup({ "/opt/kumomta/etc/policy/dkim_data.toml" })

--[[
# TRAFFIC SHAPING AUTOMATION (TSA)
# Load Traffic Shaping Automation Helper for dynamic shaping rules.
# TSA allows real-time adjustment of delivery rates based on reputation.
# See: https://docs.kumomta.com/userguide/configuration/trafficshaping/
]]
local shaping = require("policy-extras.shaping")
local shaper = shaping:setup_with_automation({
	-- Pre-filter enables early shaping decisions
	pre_filter = true,
	-- TSA publish/subscribe endpoints for shaping updates
	-- Default assumes same namespace, but should be set via env var for cross-namespace
	publish = kumo.string.split(os.getenv("KUMOMTA_TSA_PUBLISH_HOST") or "http://kumomta-tsa.kumomta.svc.cluster.local:8008", ","),
	subscribe = kumo.string.split(os.getenv("KUMOMTA_TSA_SUBSCRIBE_HOST") or "http://kumomta-tsa.kumomta.svc.cluster.local:8008", ","),
	-- Custom shaping rules file
	extra_files = { "/opt/kumomta/etc/policy/shaping.toml" },
})

--[[
# QUEUE MANAGEMENT CONFIGURATION
# Configure queue management settings. These control how messages flow
# through the queues (age limits, retry intervals, etc.), not throttles.
# WARNING: Ensure that webhooks and shaping are setup BEFORE the queue
# helper for proper operation.
# WARNING: This requires the queues.toml file to be in place.
# See: https://docs.kumomta.com/userguide/configuration/queuemanagement/
]]
local queue_module = require("policy-extras.queue")
local queue_helper = queue_module:setup({ "/opt/kumomta/etc/policy/queues.toml" })

--[[
###############################################################################
# EVENT HANDLERS
###############################################################################
# KumoMTA uses event-driven architecture. We define handlers for various
# lifecycle events and message processing stages.
###############################################################################
]]

--[[
# INIT EVENT HANDLER
# Called on startup to configure the MTA instance.
# This is where we define spools, logging, listeners, and shared services.
]]
kumo.on("init", function()
	--[[
	# SPOOL CONFIGURATION
	# Define persistent storage for messages.
	# - data spool: stores message bodies
	# - meta spool: stores envelope and metadata
	# Using RocksDB for high-performance persistent storage.
	# See: https://docs.kumomta.com/userguide/configuration/spool/
	]]
	kumo.define_spool({
		name = "data",
		path = "/var/spool/kumomta/data",
		kind = "RocksDB",
	})

	kumo.define_spool({
		name = "meta",
		path = "/var/spool/kumomta/meta",
		kind = "RocksDB",
	})

	--[[
	# THREAD CONFIGURATION
	# Configure thread pools for spool operations and HTTP injection.
	# These values can be tuned based on workload and CPU availability.
	]]
	kumo.set_spoolin_threads(os.getenv("KUMOMTA_SPOOLIN_THREADS") or 8)
	kumo.set_httpinject_threads(os.getenv("KUMOMTA_HTTPIN_THREADS") or 8)

	--[[
	# REDIS THROTTLES CONFIGURATION
	# Use shared throttles and connection limits via Redis rather than
	# in-process throttles. This enables coordination across multiple
	# KumoMTA pods in a Kubernetes deployment.
	# TODO: Consider implementing Redis authentication for production.
	]]
	local REDIS_CLUSTER_MODE = false
	if os.getenv("KUMOMTA_REDIS_CLUSTER_MODE") == "true" then
		REDIS_CLUSTER_MODE = true
	end
	kumo.configure_redis_throttles({
		node = os.getenv("KUMOMTA_REDIS_HOST") or "redis://kumomta-redis",
		cluster = REDIS_CLUSTER_MODE,
		pool_size = tonumber(os.getenv("KUMOMTA_REDIS_POOL_SIZE") or "100"),
		read_from_replicas = os.getenv("KUMOMTA_REDIS_READ_FROM_REPLICAS") ~= "false",
		username = os.getenv("KUMOMTA_REDIS_USERNAME") or nil,
		password = os.getenv("KUMOMTA_REDIS_PASSWORD") or nil,
	})

	--[[
	# LOGGING CONFIGURATION
	# Configure logging to local disk. Separating spool and logs to separate
	# volumes helps reduce IO load and can improve performance.
	# In Kubernetes, logs are typically collected via sidecar or DaemonSet.
	# See: https://docs.kumomta.com/userguide/configuration/logging/
	]]
	kumo.configure_local_logs({
		log_dir = "/var/log/kumomta",
		max_segment_duration = "1 minute",
	})

	--[[
	# SMTP LISTENER
	# Enable SMTP listener for receiving mail via SMTP protocol.
	# This allows applications to send emails via SMTP (port 2500).
	# relay_hosts defines which IPs/networks are allowed to relay mail.
	# "0.0.0.0/0" allows all IPs (adjust for production security)
	]]
	kumo.start_esmtp_listener({
		listen = "0.0.0.0:2500",
		relay_hosts = { "0.0.0.0/0" },
	})

	--[[
	# HTTP LISTENER CONFIGURATION
	# Configure HTTP listener for message injection and management APIs.
	# This is the primary interface for injecting messages into KumoMTA.
	# See: https://docs.kumomta.com/userguide/configuration/httplisteners/
	]]
	kumo.start_http_listener({
		listen = "0.0.0.0:8000",
		trusted_hosts = kumo.string.split(os.getenv("KUMOMTA_TRUSTED_HOSTS") or "0.0.0.0", ","),
	})

	--[[
	# BOUNCE CLASSIFICATION
	# Configure bounce classification to properly categorize delivery failures.
	# This helps with retry logic and bounce handling.
	# See: https://docs.kumomta.com/userguide/configuration/bounce/
	]]
	kumo.configure_bounce_classifier({
		files = {
			"/opt/kumomta/share/bounce_classifier/iana.toml",
		},
	})

	-- Initialize TSA publisher for shaping automation
	shaper.setup_publish()
end)

--[[
# EGRESS PATH CONFIGURATION
# Configure traffic shaping rules for outbound email delivery.
# The TSA helper dynamically adjusts shaping based on reputation.
]]
kumo.on("get_egress_path_config", shaper.get_egress_path_config)

--[[
# HTTP MESSAGE GENERATED EVENT HANDLER
# Called when a message is injected via HTTP API.
# This is where we apply queue management, routing, and DKIM signing.
]]
kumo.on("http_message_generated", function(msg)
	--[[
	# MESSAGE CONFORMANCE CHECKING
	# Validate and fix message conformance issues.
	# - Reject messages with critical issues (MISSING_COLON_VALUE)
	# - Auto-fix common issues (missing headers, line endings, etc.)
	# This ensures messages meet SMTP standards before processing.
	]]
	local failed = msg:check_fix_conformance(
		-- Check for and reject messages with these issues:
		"MISSING_COLON_VALUE",
		-- Fix messages with these issues:
		"LINE_TOO_LONG|NAME_ENDS_WITH_SPACE|NEEDS_TRANSFER_ENCODING|NON_CANONICAL_LINE_ENDINGS|MISSING_DATE_HEADER|MISSING_MESSAGE_ID_HEADER|MISSING_MIME_VERSION"
	)
	if failed then
		kumo.reject(552, string.format("5.6.0 %s", failed))
	end

	--[[
	# ROUTING AND QUEUE ASSIGNMENT
	# Apply queue management rules based on tenant, campaign, and domain.
	# This determines which queue the message will be placed in.
	]]
	queue_helper:apply(msg)

	--[[
	# SINK MODE (TESTING)
	# If sink mode is enabled, route all messages to the sink pod
	# instead of delivering to real recipients. Useful for testing.
	]]
	if os.getenv("KUMOMTA_SINK_ENABLED") == "true" then
		-- Default assumes namespace 'kumomta', but should be set via env var
		msg:set_meta("routing_domain", os.getenv("KUMOMTA_SINK_ENDPOINT") or "kumomta-sink.kumomta.svc.cluster.local")
	end

	--[[
	# DKIM SIGNING
	# CRITICAL: DKIM signing MUST come last, after all message modifications.
	# Signing before other operations could invalidate the DKIM signature.
	# The dkim_signer will sign messages from example.com based on
	# configuration in dkim_data.toml.
	]]
	dkim_signer(msg)
end)

--[[
# SMTP MESSAGE RECEIVED EVENT HANDLER
# Called when a message is received via SMTP listener.
# This applies the same processing as HTTP messages: queue management, routing, and DKIM signing.
]]
kumo.on("smtp_server_message_received", function(msg)
	--[[
	# MESSAGE CONFORMANCE CHECKING
	# Validate and fix message conformance issues.
	# Protects against SMTP Smuggling and ensures messages meet SMTP standards.
	# See: https://sec-consult.com/blog/detail/smtp-smuggling-spoofing-e-mails-worldwide/
	]]
	local failed = msg:check_fix_conformance(
		-- Check for and reject messages with these issues:
		"NON_CANONICAL_LINE_ENDINGS",
		-- Fix messages with these issues:
		"LINE_TOO_LONG|NAME_ENDS_WITH_SPACE|NEEDS_TRANSFER_ENCODING|MISSING_DATE_HEADER|MISSING_MESSAGE_ID_HEADER|MISSING_MIME_VERSION"
	)
	if failed then
		kumo.reject(552, string.format("5.6.0 %s", failed))
	end

	--[[
	# ROUTING AND QUEUE ASSIGNMENT
	# Apply queue management rules based on tenant, campaign, and domain.
	# This determines which queue the message will be placed in.
	]]
	queue_helper:apply(msg)

	--[[
	# SINK MODE (TESTING)
	# If sink mode is enabled, route all messages to the sink pod
	# instead of delivering to real recipients. Useful for testing.
	# This ensures SMTP messages are also intercepted, just like HTTP messages.
	]]
	if os.getenv("KUMOMTA_SINK_ENABLED") == "true" then
		-- Default assumes namespace 'kumomta', but should be set via env var
		msg:set_meta("routing_domain", os.getenv("KUMOMTA_SINK_ENDPOINT") or "kumomta-sink.kumomta.svc.cluster.local")
	end

	--[[
	# DKIM SIGNING
	# CRITICAL: DKIM signing MUST come last, after all message modifications.
	# Signing before other operations could invalidate the DKIM signature.
	# The dkim_signer will sign messages from example.com based on
	# configuration in dkim_data.toml.
	]]
	dkim_signer(msg)
end)

--[[
# ROUTING DOMAIN CONFIGURATION (OPTIONAL)
# Customize routing behavior based on destination domain.
# This can be used for domain-specific routing rules, IP pools, etc.
# Uncomment and customize as needed for example.com requirements.
]]
-- kumo.on("get_egress_path_config", function(routing_domain, egress_source, site_name)
-- 	-- Example: Special handling for specific domains
-- 	if routing_domain == "gmail.com" then
-- 		return kumo.make_egress_path {
-- 			connection_limit = 100,
-- 			max_message_rate = "100/s",
-- 			enable_tls = "Required",
-- 		}
-- 	end
-- 	-- Default shaping handled by TSA
-- 	return nil
-- end)

--[[
# HTTP AUTHENTICATION VALIDATION
# Validate HTTP Basic Auth credentials for the HTTP API.
# Credentials are stored in Kubernetes Secrets mounted at:
# /opt/kumomta/etc/http_listener_keys/
# Secret format:
#   data:
#     username: <base64-encoded-password>
# See: https://docs.kumomta.com/userguide/configuration/httplisteners/
]]
kumo.on("http_server_validate_auth_basic", function(user, password)
	return cached_get_auth(user, password)
end)

--[[
###############################################################################
# UTILITY FUNCTIONS
###############################################################################
# Helper functions for authentication and other operations.
###############################################################################
]]

--[[
# AUTHENTICATION HELPER FUNCTIONS
# These functions validate HTTP Basic Auth credentials by reading from
# mounted Kubernetes Secrets.
# 
# Kubernetes Secret mounting:
# - Secret keys should be usernames
# - Secret values should be passwords (base64 decoded automatically)
# - Mount path: /opt/kumomta/etc/http_listener_keys/
# 
# Example Secret creation:
#   kubectl create secret generic http-listener-keys \
#     --from-literal=api-user=$(openssl rand -hex 16)
]]
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

-- Memoize authentication checks to reduce file I/O
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

-- Memoize file existence checks
cached_auth_file_exists = kumo.memoize(auth_file_exists, {
	name = "auth_file_exists",
	ttl = "1 minute",
	capacity = 2,
})
