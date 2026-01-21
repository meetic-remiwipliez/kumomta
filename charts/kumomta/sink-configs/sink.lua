--[[
########################################################
This config runs a sink that accepts mail over smtp
and then drops it. It can be used to test sending mail
through kumo without delivering to real mailboxes
########################################################
]]
local kumo = require("kumo")
kumo.on("init", function()
	kumo.configure_accounting_db_path(os.tmpname())
	kumo.start_esmtp_listener({
		listen = "0.0.0.0:25",
		relay_hosts = { "0.0.0.0/0" },
		deferred_spool = true,
	})

	kumo.start_http_listener({
		listen = "0.0.0.0:8000",
	})

	kumo.define_spool({
		name = "data",
		path = "/var/spool/kumomta/data",
	})

	kumo.define_spool({
		name = "meta",
		path = "/var/spool/kumomta/meta",
	})

	kumo.configure_local_logs({
		log_dir = "/var/log/kumomta",
		-- Flush logs every 10 seconds.
		-- You may wish to set a larger value in your production
		-- configuration; this lower value makes it quicker to see
		-- logs while you are first getting set up.
		max_segment_duration = "10s",
	})
	
	-- Enable debug logging for sink component
	kumo.set_diagnostic_log_filter("kumod=debug,lua=debug,http=debug,smtp=debug")
end)
--[[ End of INIT Section ]]

-- Helper function to extract message information for logging
local function get_message_info(msg)
	local sender = msg:sender()
	local recipients = {}
	local recipient_count = 0
	
	-- In smtp_server_message_received, recipient() should work with index 0
	-- For multi-recipient messages, smtp_server_message_received may be called once per recipient
	-- So we typically have one recipient at index 0
	local recipient = msg:recipient(0)
	if recipient then
		table.insert(recipients, tostring(recipient))
		recipient_count = 1
	end
	
	-- Fallback: try to get recipient from To header if recipient() doesn't work
	if recipient_count == 0 then
		local to_header = msg:to_header()
		if to_header then
			-- Extract email addresses from To header
			-- to_header() returns a table, so we need to handle it properly
			if type(to_header) == "table" then
				for _, addr in ipairs(to_header) do
					if addr and addr ~= "" then
						table.insert(recipients, tostring(addr))
						recipient_count = recipient_count + 1
					end
				end
			elseif type(to_header) == "string" then
				-- Extract email addresses from string
				for addr in tostring(to_header):gmatch("[%w%._%-]+@[%w%._%-]+") do
					table.insert(recipients, addr)
					recipient_count = recipient_count + 1
				end
			end
		end
	end
	
	local queue = msg:get_meta("queue") or "unknown"
	local message_id = msg:get_first_named_header_value("Message-ID") or "no-message-id"
	local subject = msg:get_first_named_header_value("Subject") or "no-subject"
	local tenant = msg:get_first_named_header_value("X-Tenant") or msg:get_meta("tenant") or "no-tenant"
	local binding_group = msg:get_meta("binding_group") or msg:get_meta("BindingGroup") or "no-binding-group"
	
	return {
		sender = sender or "unknown",
		recipients = recipients,
		recipient_count = recipient_count,
		queue = queue,
		message_id = message_id,
		subject = subject,
		tenant = tenant,
		binding_group = binding_group,
	}
end

-- Handler for SMTP messages received
kumo.on("smtp_server_message_received", function(msg)
	local info = get_message_info(msg)
	
	-- Log detailed message information
	kumo.log_info(string.format(
		"[SINK] SMTP message received - Sender: %s | Recipients: %s (%d) | Queue: %s | Tenant: %s | BindingGroup: %s | Subject: %s | Message-ID: %s",
		info.sender,
		table.concat(info.recipients, ", "),
		info.recipient_count,
		info.queue,
		info.tenant,
		info.binding_group,
		info.subject,
		info.message_id
	))
	
	-- Accept and discard all messages
	msg:set_meta("queue", "null")
end)

-- Handler for HTTP messages generated
kumo.on("http_message_generated", function(msg)
	local info = get_message_info(msg)
	
	-- Log detailed message information
	kumo.log_info(string.format(
		"[SINK] HTTP message received - Sender: %s | Recipients: %s (%d) | Queue: %s | Tenant: %s | BindingGroup: %s | Subject: %s | Message-ID: %s",
		info.sender,
		table.concat(info.recipients, ", "),
		info.recipient_count,
		info.queue,
		info.tenant,
		info.binding_group,
		info.subject,
		info.message_id
	))
	
	-- Accept and discard all messages
	msg:set_meta("queue", "null")
end)
