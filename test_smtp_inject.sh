#!/bin/bash
#
# Test script for KumoMTA SMTP listener
# Based on test_example.com.json
#
# Usage:
#   ./test_smtp_inject.sh [namespace] [context]
#
# Example:
#   ./test_smtp_inject.sh kumomta dal-lab
#
# Requirements:
#   - swaks (Swiss Army Knife for SMTP) or
#   - telnet/netcat for basic SMTP testing
#

set -e

NAMESPACE="${1:-kumomta}"
CONTEXT="${2:-dal-lab}"
SERVICE_NAME="kumomta"
SMTP_PORT=2500

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== KumoMTA SMTP Injection Test ===${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl --context="${CONTEXT}" get namespace "${NAMESPACE}" &> /dev/null; then
    echo -e "${RED}Error: Namespace '${NAMESPACE}' does not exist${NC}"
    exit 1
fi

# Check if service exists
if ! kubectl --context="${CONTEXT}" get svc "${SERVICE_NAME}" -n "${NAMESPACE}" &> /dev/null; then
    echo -e "${RED}Error: Service '${SERVICE_NAME}' does not exist in namespace '${NAMESPACE}'${NC}"
    exit 1
fi

# Read test payload
TEST_FILE="test_example.com.json"
if [ ! -f "${TEST_FILE}" ]; then
    echo -e "${RED}Error: Test file '${TEST_FILE}' not found${NC}"
    exit 1
fi

# Extract values from JSON
ENVELOPE_SENDER=$(jq -r '.envelope_sender' "${TEST_FILE}")
FROM_EMAIL=$(jq -r '.content.from.email' "${TEST_FILE}")
FROM_NAME=$(jq -r '.content.from.name' "${TEST_FILE}")
SUBJECT=$(jq -r '.content.subject' "${TEST_FILE}")
TEXT_BODY=$(jq -r '.content.text_body' "${TEST_FILE}")
HTML_BODY=$(jq -r '.content.html_body' "${TEST_FILE}")
RECIPIENT=$(jq -r '.recipients[0].email' "${TEST_FILE}")

echo "Test configuration:"
echo "  From: ${FROM_NAME} <${FROM_EMAIL}>"
echo "  To: ${RECIPIENT}"
echo "  Subject: ${SUBJECT}"
echo "  Envelope Sender: ${ENVELOPE_SENDER}"
echo ""

# Start port-forward in background
echo -e "${YELLOW}Starting port-forward to ${SERVICE_NAME}:${SMTP_PORT}...${NC}"
kubectl --context="${CONTEXT}" port-forward -n "${NAMESPACE}" svc/"${SERVICE_NAME}" ${SMTP_PORT}:${SMTP_PORT} > /dev/null 2>&1 &
PORT_FORWARD_PID=$!

# Wait for port-forward to be ready
sleep 2

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up port-forward...${NC}"
    kill ${PORT_FORWARD_PID} 2>/dev/null || true
    wait ${PORT_FORWARD_PID} 2>/dev/null || true
}

trap cleanup EXIT

# Check if port-forward is working
if ! nc -z localhost ${SMTP_PORT} 2>/dev/null; then
    echo -e "${RED}Error: Could not connect to KumoMTA SMTP port${NC}"
    echo "Make sure the service is running and SMTP listener is enabled"
    exit 1
fi

echo -e "${GREEN}✓ Port-forward established${NC}"
echo ""

# Check if swaks is available
if command -v swaks &> /dev/null; then
    echo -e "${YELLOW}Using swaks for SMTP injection...${NC}"
    echo ""
    
    # Create temporary files for message content
    TEXT_FILE=$(mktemp)
    HTML_FILE=$(mktemp)
    echo "${TEXT_BODY}" > "${TEXT_FILE}"
    echo "${HTML_BODY}" > "${HTML_FILE}"
    
    # Send email via swaks
    if swaks \
        --to "${RECIPIENT}" \
        --from "${ENVELOPE_SENDER}" \
        --h-From: "\"${FROM_NAME}\" <${FROM_EMAIL}>" \
        --h-Subject: "${SUBJECT}" \
        --body "${TEXT_FILE}" \
        --add-header "Content-Type: text/plain; charset=UTF-8" \
        --server localhost:${SMTP_PORT} \
        --no-tls \
        --quit-after RCPT; then
        echo ""
        echo -e "${GREEN}✓ SMTP injection successful!${NC}"
        rm -f "${TEXT_FILE}" "${HTML_FILE}"
        exit 0
    else
        echo ""
        echo -e "${RED}✗ SMTP injection failed${NC}"
        rm -f "${TEXT_FILE}" "${HTML_FILE}"
        exit 1
    fi
    
elif command -v telnet &> /dev/null || command -v nc &> /dev/null; then
    echo -e "${YELLOW}Using telnet/nc for basic SMTP test...${NC}"
    echo ""
    echo -e "${YELLOW}Note: This is a basic SMTP test. For full functionality, install swaks:${NC}"
    echo "  macOS: brew install swaks"
    echo "  Linux: apt-get install swaks or yum install swaks"
    echo ""
    
    # Basic SMTP test using telnet/nc
    SMTP_CMD=""
    if command -v telnet &> /dev/null; then
        SMTP_CMD="telnet"
    elif command -v nc &> /dev/null; then
        SMTP_CMD="nc"
    fi
    
    if [ -n "${SMTP_CMD}" ]; then
        echo "Testing SMTP connection..."
        (
            echo "EHLO localhost"
            sleep 1
            echo "MAIL FROM:<${ENVELOPE_SENDER}>"
            sleep 1
            echo "RCPT TO:<${RECIPIENT}>"
            sleep 1
            echo "DATA"
            sleep 1
            echo "From: ${FROM_NAME} <${FROM_EMAIL}>"
            echo "To: ${RECIPIENT}"
            echo "Subject: ${SUBJECT}"
            echo "Content-Type: text/plain; charset=UTF-8"
            echo ""
            echo "${TEXT_BODY}"
            echo "."
            sleep 1
            echo "QUIT"
        ) | ${SMTP_CMD} localhost ${SMTP_PORT}
        
        if [ $? -eq 0 ]; then
            echo ""
            echo -e "${GREEN}✓ SMTP connection test completed${NC}"
            exit 0
        else
            echo ""
            echo -e "${RED}✗ SMTP connection test failed${NC}"
            exit 1
        fi
    fi
else
    echo -e "${RED}Error: Neither swaks nor telnet/nc is available${NC}"
    echo ""
    echo "Please install one of the following:"
    echo "  - swaks (recommended): brew install swaks"
    echo "  - telnet or nc (basic testing)"
    exit 1
fi
