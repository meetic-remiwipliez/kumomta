# KumoMTA Test Scripts

This directory contains test scripts to verify KumoMTA HTTP and SMTP listener behavior.

## 📋 Prerequisites

### For All Scripts
- `kubectl` configured and connected to the Kubernetes cluster
- Access to the namespace where KumoMTA is deployed

### For Bash Scripts
- `jq` (for parsing the JSON configuration file)
- For SMTP: `swaks`, `telnet`, or `nc` (netcat)
- For HTTP: `curl`

### For Python Scripts (Recommended)
- Python 3.6 or higher
- `requests` library (for HTTP)

### Installing Missing Tools

**macOS:**
```bash
# For Bash scripts
brew install jq swaks telnet curl

# Python and dependencies
brew install python3
pip3 install -r requirements.txt
```

**Linux (Debian/Ubuntu):**
```bash
# For Bash scripts
sudo apt-get install jq swaks telnet netcat-openbsd curl

# Python and dependencies
sudo apt-get install python3 python3-pip
pip3 install -r requirements.txt
```

## 📁 File Layout

```
tests/
├── README.md                    # This file
├── requirements.txt             # Python dependencies
├── test_payload_generic.json    # Test data configuration (editable)
├── test_http_listener.sh        # HTTP listener test (Bash)
├── test_smtp_listener.sh         # SMTP listener test (Bash)
├── test_performance_http.sh     # HTTP performance test (Bash)
├── test_performance_smtp.sh     # SMTP performance test (Bash)
├── test_performance_http.py     # HTTP performance test (Python – recommended)
└── test_performance_smtp.py     # SMTP performance test (Python – recommended)
```

## 🚀 Python Scripts (Recommended)

Python scripts provide better error handling and more reliable success/failure detection.

### HTTP Performance Test
```bash
# 50 messages, 5 threads (default)
python3 test_performance_http.py

# Custom message count
python3 test_performance_http.py 100

# Message count and thread count
python3 test_performance_http.py 100 10

# Via environment variables
NUM_MESSAGES=100 MAX_THREADS=10 python3 test_performance_http.py
```

### SMTP Performance Test
```bash
# 50 messages, 5 threads (default)
python3 test_performance_smtp.py

# Custom message count
python3 test_performance_smtp.py 100

# Message count and thread count
python3 test_performance_smtp.py 100 10

# Via environment variables
NUM_MESSAGES=100 MAX_THREADS=10 python3 test_performance_smtp.py
```

### Python Script Parameters

- **num_messages** (first argument): Number of messages to send (default: 50)
- **num_threads** (second argument): Number of threads for parallelism (default: 5)

Parameters can be passed:
- As command-line arguments: `python3 script.py 100 10`
- Via environment variables: `NUM_MESSAGES=100 MAX_THREADS=10 python3 script.py`

### Benefits of Python Scripts
- ✅ More reliable success/failure detection (HTTP and SMTP response codes)
- ✅ More robust error handling
- ✅ More reliable response parsing
- ✅ Detailed stats (mean, median, percentiles)
- ✅ CSV export of results
- ✅ Automatic Kubernetes port-forward handling
- ✅ Threaded execution (configurable, default: 5)
- ✅ Automatic venv and dependency handling

## ⚙️ Configuration

### File `test_payload_generic.json`

This file holds all test data used by both scripts. **Edit it once** to change parameters for both tests.

```json
{
  "from_email": "test@talk.stir.com",
  "to_email": "test@example.com",
  "from_name": "KumoMTA Test",
  "subject": "Test KumoMTA - {{TIMESTAMP}}",
  "text_body": "...",
  "html_body": "...",
  "reply_to_email": "test@talk.stir.com",
  "reply_to_name": "KumoMTA Test"
}
```

**Variables:**
- `{{TIMESTAMP}}`: Replaced with current date/time as `YYYY-MM-DD HH:MM:SS`

**Fields:**
- `from_email`: Sender (binding group domain)
- `to_email`: Recipient
- `from_name`: Sender display name
- `subject`: Subject (may include `{{TIMESTAMP}}`)
- `text_body`: Plain text body (may include `{{TIMESTAMP}}`)
- `html_body`: HTML body (may include `{{TIMESTAMP}}`)
- `reply_to_email`: Reply-to address
- `reply_to_name`: Reply-to display name

## 🚀 Usage

### HTTP Listener Test

`test_http_listener.sh` tests message injection via the KumoMTA HTTP API.

```bash
cd tests
./test_http_listener.sh
```

**Defaults:**
- Namespace: `kumomta`
- Service: `kumomta` (auto-detected if different)
- Local port: `8000`
- Auth: `user1` / `default-password`

**Overrides via environment:**
```bash
NAMESPACE=production \
RELEASE_NAME=kumomta-prod \
LOCAL_HTTP_PORT=8080 \
HTTP_USER=admin \
HTTP_PASSWORD=my-secure-password \
PAYLOAD_FILE=./custom_payload.json \
./test_http_listener.sh
```

### SMTP Listener Test

`test_smtp_listener.sh` tests message submission via SMTP.

```bash
cd tests
./test_smtp_listener.sh
```

**Defaults:**
- Namespace: `kumomta`
- Service: `kumomta` (auto-detected if different)
- Local port: `2500`

**Overrides via environment:**
```bash
NAMESPACE=production \
RELEASE_NAME=kumomta-prod \
LOCAL_SMTP_PORT=2525 \
PAYLOAD_FILE=./custom_payload.json \
./test_smtp_listener.sh
```

## 🔧 How It Works

Both scripts:

1. **Load JSON** – Read data from `test_payload_generic.json` (or a custom file)
2. **Check Kubernetes service** – Ensure the KumoMTA service exists
3. **Port-forward** – Create a local tunnel to the service
4. **Connect** – Check that the listener responds
5. **Send** – Send a test message using the JSON payload
6. **Check** – Print the result and return codes

Port-forward is cleaned up at the end (or on interrupt).

## 📊 Expected Results

### Successful HTTP Test

```
=== KumoMTA HTTP Listener Test ===
Service: kumomta
Namespace: kumomta
Local port: 8000
Payload file: ./test_payload_generic.json
From: test@talk.stir.com
To: test@example.com

✓ Service found
✓ Port-forward active (PID: 12345)
✓ HTTP connection OK
✓ Message sent successfully (HTTP 200)

=== HTTP Test Passed ===
```

### Successful SMTP Test

```
=== KumoMTA SMTP Listener Test ===
Service: kumomta
Namespace: kumomta
Local port: 2500
Payload file: ./test_payload_generic.json
From: test@talk.stir.com
To: test@example.com

✓ Service found
✓ Pod found: kumomta-kumomta-0
✓ SMTP listener appears to be configured
✓ Port-forward active (PID: 12345)
✓ Message sent successfully via SMTP

=== SMTP Test Passed ===
```

## 🐛 Troubleshooting

### JSON File Not Found

- Ensure `test_payload_generic.json` is in the same directory as the scripts
- Or set `PAYLOAD_FILE=/path/to/file.json`

### jq Not Installed

```bash
# macOS
brew install jq

# Linux
sudo apt-get install jq
```

### Port-Forward Fails

- Check that the local port is free
- Change `LOCAL_HTTP_PORT` or `LOCAL_SMTP_PORT` if needed
- Ensure you have permissions in the cluster

### HTTP Test Fails with 401

- Check HTTP credentials in the `http-listener-keys` secret
- Use `HTTP_USER` and `HTTP_PASSWORD` for the correct values

### SMTP Test Fails

- Ensure the SMTP listener is enabled in `init.lua`
- Check pod logs: `kubectl logs -n <namespace> <pod-name> --tail=50`
- Confirm the SMTP port (default 2500)

### Service Not Found

- List services: `kubectl get services -n <namespace>`
- Adjust `SERVICE_NAME` or `RELEASE_NAME` for your setup

## 📝 Notes

- Scripts use `talk.stir.com` (StirTalk binding group) as the default sending domain
- Messages are sent to `test@example.com` (standard test domain)
- In sink mode (default), messages go to the sink service instead of real recipients
- Port-forward is cleaned up on interrupt (e.g. Ctrl+C)
- `test_payload_generic.json` is the default; you can pass another file: `./test_http_listener.sh my_file.json`
- Both scripts can share the same JSON file or use different ones

## 🔗 Links

- [KumoMTA HTTP API](https://docs.kumomta.com/reference/http_api/)
- [KumoMTA SMTP Listener](https://docs.kumomta.com/userguide/configuration/smtplisteners/)
