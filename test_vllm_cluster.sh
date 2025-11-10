#!/usr/bin/env bash
set -eu

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DGX Spark vLLM Cluster - Test Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

HEAD_IP="${HEAD_IP:-}"  # Set via: export HEAD_IP=<your-head-ip>
CONTAINER="${CONTAINER:-ray-head}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

test_pass() {
  echo -e "${GREEN}✅ PASS${NC}: $1"
}

test_fail() {
  echo -e "${RED}❌ FAIL${NC}: $1"
}

test_warn() {
  echo -e "${YELLOW}⚠️  WARN${NC}: $1"
}

section() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

section "Test 1: Container Status"

if docker ps | grep -q "${CONTAINER}"; then
  test_pass "Container '${CONTAINER}' is running"
else
  test_fail "Container '${CONTAINER}' is not running"
  echo "  Run: bash start_head_production.sh"
  exit 1
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

section "Test 2: Ray Status"

if docker exec "${CONTAINER}" ray status --address=127.0.0.1:6379 >/dev/null 2>&1; then
  test_pass "Ray cluster is healthy"

  # Count nodes
  NODES=$(docker exec "${CONTAINER}" ray status --address=127.0.0.1:6379 2>/dev/null | grep -A20 "Healthy:" | grep "node_" | wc -l)
  echo "  Healthy nodes: ${NODES}"

  # Show resources
  echo ""
  docker exec "${CONTAINER}" ray status --address=127.0.0.1:6379 2>/dev/null | grep -A10 "Resources"
else
  test_fail "Ray cluster is not responding"
  echo "  Check logs: docker exec ${CONTAINER} ray status --address=127.0.0.1:6379"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

section "Test 3: vLLM Health"

if curl -sf "http://${HEAD_IP}:8000/health" >/dev/null 2>&1; then
  test_pass "vLLM health endpoint responding"
else
  test_fail "vLLM health endpoint not responding"
  echo "  Check logs: docker exec ${CONTAINER} tail -50 /var/log/vllm.log"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

section "Test 4: List Models"

MODELS_OUTPUT=$(curl -sf "http://${HEAD_IP}:8000/v1/models" 2>/dev/null || echo "")
MODEL_ID="unknown"

if [ -n "${MODELS_OUTPUT}" ]; then
  MODEL_ID=$(echo "${MODELS_OUTPUT}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null || echo "unknown")
  test_pass "Model endpoint responding"
  echo "  Available model: ${MODEL_ID}"
else
  test_fail "Model endpoint not responding"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

section "Test 5: Simple Inference"

echo "Testing chat completion (this may take 10-30 seconds)..."

INFERENCE_OUTPUT=$(curl -sf "http://${HEAD_IP}:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_ID}"'",
    "messages": [{"role": "user", "content": "Say only the word: SUCCESS"}],
    "max_tokens": 10,
    "temperature": 0.1
  }' 2>/dev/null || echo "")

if [ -n "${INFERENCE_OUTPUT}" ]; then
  RESPONSE=$(echo "${INFERENCE_OUTPUT}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])' 2>/dev/null || echo "")

  if [ -n "${RESPONSE}" ]; then
    test_pass "Inference completed successfully"
    echo "  Response: ${RESPONSE}"
  else
    test_warn "Inference returned empty response"
    echo "  Raw output: ${INFERENCE_OUTPUT}"
  fi
else
  test_fail "Inference request failed"
  echo "  Check vLLM logs for errors"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

section "Test 6: GPU Utilization"

echo "Current GPU status:"
nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null || echo "nvidia-smi not available"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

section "Test 7: Network Connectivity"

echo "Testing Ray ports..."

for PORT in 6379 8265 8000; do
  if nc -zv -w 2 "${HEAD_IP}" "${PORT}" 2>&1 | grep -q "succeeded"; then
    test_pass "Port ${PORT} is accessible"
  else
    test_fail "Port ${PORT} is not accessible"
  fi
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

section "Summary"

echo ""
echo "🌐 Dashboards:"
echo "   Ray:  http://${HEAD_IP}:8265"
echo "   vLLM: http://${HEAD_IP}:8000/docs"
echo ""
echo "🔍 Diagnostic Commands:"
echo "   # Ray cluster details"
echo "   docker exec ${CONTAINER} ray status --address=127.0.0.1:6379"
echo ""
echo "   # vLLM logs"
echo "   docker exec ${CONTAINER} tail -f /var/log/vllm.log"
echo ""
echo "   # Container logs"
echo "   docker logs -f ${CONTAINER}"
echo ""
echo "   # GPU monitoring"
echo "   watch -n 1 nvidia-smi"
echo ""

section "Test Complete"
