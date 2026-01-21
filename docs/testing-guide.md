# KumoMTA Testing Guide

This guide describes how to test KumoMTA HTTP and SMTP listeners using the provided scripts.

## 📋 Prerequisites

- `kubectl` configured with cluster access
- `jq` for JSON parsing (installed by default on macOS, `brew install jq` on Linux)
- For SMTP tests: `swaks` (recommended) or `telnet`/`nc` (basic)

### Installing swaks

```bash
# macOS
brew install swaks

# Linux (Debian/Ubuntu)
apt-get install swaks

# Linux (RHEL/CentOS)
yum install swaks
```

## 🧪 Available Tests

### 1. HTTP Injection Test (`test_http_inject.sh`)

Tests KumoMTA HTTP injection API using the `test_example.com.json` file.

**Usage:**
```bash
./test_http_inject.sh [namespace] [context]
```

**Examples:**
```bash
# Uses default values (namespace: kumomta, context: dal-lab)
./test_http_inject.sh

# Specify namespace and context
./test_http_inject.sh kumomta dal-lab
```

**What the script does:**
1. Verifies that the namespace and service exist
2. Retrieves API credentials from the `http-listener-keys` secret
3. Establishes a port-forward to the HTTP service (port 8000)
4. Sends the JSON payload via the `/api/inject/v1` endpoint
5. Displays the response and HTTP code

**Payload format:**
The script uses `test_example.com.json` which contains:
- `envelope_sender`: The sending address (envelope)
- `content`: The email content (from, subject, text_body, html_body)
- `recipients`: List of recipients

### 2. SMTP Injection Test (`test_smtp_inject.sh`)

Tests KumoMTA SMTP listener using the `test_example.com.json` file.

**Usage:**
```bash
./test_smtp_inject.sh [namespace] [context]
```

**Examples:**
```bash
# Uses default values
./test_smtp_inject.sh

# Specify namespace and context
./test_smtp_inject.sh kumomta dal-lab
```

**What the script does:**
1. Verifies that the namespace and service exist
2. Parses the JSON file to extract email information
3. Establishes a port-forward to the SMTP service (port 2500)
4. Sends the email via SMTP using `swaks` (if available) or `telnet`/`nc`
5. Displays the result

**Note:** The SMTP listener must be enabled in the KumoMTA configuration. By default, it is disabled in `init.lua`. To enable it, uncomment:
```lua
kumo.start_esmtp_listener({
  listen = "0.0.0.0:2500",
  relay_hosts = { "0.0.0.0/0" },
})
```

## 📝 Test File

The `test_example.com.json` file contains a test email example for the `example.com` domain:

```json
{
  "envelope_sender": "test@example.com",
  "content": {
    "text_body": "Hello,\n\nThis is a test message...",
    "html_body": "<html><body>...</body></html>",
    "from": {
      "email": "test@example.com",
      "name": "Example.com Team"
    },
    "subject": "Test Example.com - Authorized Domain",
    "reply_to": {
      "email": "support@example.com",
      "name": "Example.com Support"
    }
  },
  "recipients": [
    {
      "email": "r.wipliez@meetic-corp.com"
    }
  ]
}
```

You can modify this file to test different scenarios.

## 🔍 Verifying Results

### For HTTP Injection

A success returns an HTTP 200 or 202 code with a JSON response containing injection details.

### For SMTP Injection

A success displays SMTP server responses (220, 250, etc.) and confirms message acceptance.

### Check Logs

```bash
# MTA pod logs
kubectl --context=dal-lab logs -n kumomta -l app.kubernetes.io/name=kumomta --tail=50

# Sink pod logs (if SINK mode enabled)
kubectl --context=dal-lab logs -n kumomta -l app.kubernetes.io/name=kumomta-sink --tail=50
```

## 🐛 Troubleshooting

### Error: "Could not retrieve API password"

Verify that the `http-listener-keys` secret exists:
```bash
kubectl --context=dal-lab get secret http-listener-keys -n kumomta
```

### Error: "Could not connect to KumoMTA HTTP API"

Verify that the service is running:
```bash
kubectl --context=dal-lab get pods -n kumomta
kubectl --context=dal-lab get svc -n kumomta
```

### Error: "Could not connect to KumoMTA SMTP port"

Verify that the SMTP listener is enabled in the configuration. By default, it is disabled.

### Port Already in Use

If port-forward fails because the port is already in use:
```bash
# Find the process using the port
lsof -i :8000  # For HTTP
lsof -i :2500  # For SMTP

# Kill the process or use another port
```

## 📚 Resources

- [KumoMTA HTTP API Documentation](https://docs.kumomta.com/userguide/configuration/httplisteners/)
- [KumoMTA SMTP Listener Documentation](https://docs.kumomta.com/userguide/configuration/smtplisteners/)
- [Swaks Documentation](https://www.jetmore.org/john/code/swaks/)
