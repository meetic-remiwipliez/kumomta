#!/bin/bash
#
# Test script for KumoMTA HTTP injection API
# Based on test_example.com.json
#
# Usage:
#   ./test_http_inject.sh [namespace] [context]
#
# Example:
#   ./test_http_inject.sh kumomta dal-lab
#

set -e

NAMESPACE="${1:-kumomta}"
CONTEXT="${2:-dal-lab}"
SERVICE_NAME="kumomta"
HTTP_PORT=8000
API_ENDPOINT="/api/inject/v1"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== KumoMTA HTTP Injection Test ===${NC}"
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

# Get API credentials from secret
echo -e "${YELLOW}Retrieving API credentials...${NC}"
API_PASSWORD=$(kubectl --context="${CONTEXT}" get secret http-listener-keys -n "${NAMESPACE}" -o jsonpath='{.data.api-user}' 2>/dev/null | base64 -d)

if [ -z "${API_PASSWORD}" ]; then
    echo -e "${RED}Error: Could not retrieve API password from secret 'http-listener-keys'${NC}"
    exit 1
fi

echo -e "${GREEN}✓ API credentials retrieved${NC}"
echo ""

# Start port-forward in background
echo -e "${YELLOW}Starting port-forward to ${SERVICE_NAME}:${HTTP_PORT}...${NC}"
kubectl --context="${CONTEXT}" port-forward -n "${NAMESPACE}" svc/"${SERVICE_NAME}" ${HTTP_PORT}:${HTTP_PORT} > /dev/null 2>&1 &
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
if ! curl -s http://localhost:${HTTP_PORT}/api/check-liveness/v1 > /dev/null 2>&1; then
    echo -e "${RED}Error: Could not connect to KumoMTA HTTP API${NC}"
    echo "Make sure the service is running and accessible"
    exit 1
fi

echo -e "${GREEN}✓ Port-forward established${NC}"
echo ""

# Read test payload
TEST_FILE="test2_example.com.json"
if [ ! -f "${TEST_FILE}" ]; then
    echo -e "${RED}Error: Test file '${TEST_FILE}' not found${NC}"
    exit 1
fi

echo -e "${YELLOW}Sending HTTP injection request...${NC}"
echo "Endpoint: http://localhost:${HTTP_PORT}${API_ENDPOINT}"
echo "Payload: ${TEST_FILE}"
echo ""

# Send HTTP injection request
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "api-user:${API_PASSWORD}" \
    -d @"${TEST_FILE}" \
    "http://localhost:${HTTP_PORT}${API_ENDPOINT}")

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

echo -e "${YELLOW}Response:${NC}"
echo "HTTP Status: ${HTTP_CODE}"

if [ "${HTTP_CODE}" -eq 200 ] || [ "${HTTP_CODE}" -eq 202 ]; then
    echo -e "${GREEN}✓ HTTP injection successful!${NC}"
    echo ""
    echo "Response body:"
    echo "${BODY}" | jq '.' 2>/dev/null || echo "${BODY}"
    exit 0
else
    echo -e "${RED}✗ HTTP injection failed${NC}"
    echo ""
    echo "Response body:"
    echo "${BODY}"
    exit 1
fi
