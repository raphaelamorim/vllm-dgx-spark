#!/bin/bash

################################################################################
# TensorRT-LLM Safe Testing Script for DGX Spark
#
# This script tests TensorRT-LLM with CONSERVATIVE settings to avoid system
# lockups. Based on analysis of GitHub issues #8474, #8781, and #2953.
#
# WARNING: TensorRT-LLM v1.2.0rc3 has known compatibility issues with GB10 (SM120)
#          Multi-node deployments are HIGHLY UNSTABLE and likely to hang.
#
# SAFETY PROTOCOL:
#   - Test 1: Single GPU, small model (SAFE)
#   - Test 2: Single GPU with quantization (MEDIUM RISK)
#   - Test 3: Multi-node DISABLED by default (HIGH RISK - manual override required)
#
# Usage:
#   ./test_tensorrt_llm_safe.sh                    # Run safe tests only
#   ENABLE_MULTI_NODE_TEST=1 ./test_tensorrt_llm_safe.sh  # Enable risky test
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
TRTLLM_IMAGE="${TRTLLM_IMAGE:-nvcr.io/nvidia/tensorrt-llm/release:1.2.0rc3}"
TEST_MODEL_SMALL="${TEST_MODEL_SMALL:-meta-llama/Llama-3.1-8B-Instruct}"
TEST_MODEL_LARGE="${TEST_MODEL_LARGE:-meta-llama/Llama-3.3-70B-Instruct}"
TEST_PORT="${TEST_PORT:-8000}"
ENABLE_MULTI_NODE_TEST="${ENABLE_MULTI_NODE_TEST:-0}"

# Test timeout (kill container if hung)
TIMEOUT_SECONDS=300  # 5 minutes

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  TensorRT-LLM Safe Testing for DGX Spark (GB10/SM120)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}⚠️  WARNING: TensorRT-LLM has known compatibility issues with DGX Spark${NC}"
echo -e "${YELLOW}    See TENSORRT_LLM_ANALYSIS.md for details${NC}"
echo ""

# Check prerequisites
echo -e "${CYAN}Checking prerequisites...${NC}"

# Check GPU
if ! nvidia-smi &>/dev/null; then
    echo -e "${RED}✗ nvidia-smi not found. Is NVIDIA driver installed?${NC}"
    exit 1
fi

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)

echo -e "  GPU: ${GPU_NAME}"
echo -e "  Compute Capability: ${COMPUTE_CAP}"

if [[ "$COMPUTE_CAP" == "12.1" ]]; then
    echo -e "${YELLOW}  ⚠️  SM120 detected - Known compatibility issues in v1.2.0rc3${NC}"
fi

# Check Docker
if ! docker --version &>/dev/null; then
    echo -e "${RED}✗ Docker not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"
echo ""

# Function to safely run container with timeout
run_container_with_timeout() {
    local container_name=$1
    local docker_args=$2
    local timeout=$3

    echo -e "${CYAN}Starting container: ${container_name}${NC}"
    echo -e "${CYAN}Timeout: ${timeout}s${NC}"

    # Start container in background
    eval "docker run --name ${container_name} ${docker_args}" &
    local docker_pid=$!

    # Monitor with timeout
    local elapsed=0
    while kill -0 $docker_pid 2>/dev/null; do
        if [ $elapsed -ge $timeout ]; then
            echo -e "${RED}✗ TIMEOUT after ${timeout}s - Container may be hung${NC}"
            echo -e "${YELLOW}  Attempting graceful stop...${NC}"
            docker stop ${container_name} --time 10 2>/dev/null || true
            docker kill ${container_name} 2>/dev/null || true
            docker rm ${container_name} 2>/dev/null || true
            return 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done
    echo ""

    wait $docker_pid
    return $?
}

# Function to test inference
test_inference() {
    local url=$1
    local model=$2

    echo -e "${CYAN}Testing inference...${NC}"

    # Wait for server to be ready
    local max_wait=60
    local waited=0
    while ! curl -sf "${url}/health" >/dev/null 2>&1; do
        if [ $waited -ge $max_wait ]; then
            echo -e "${RED}✗ Server did not become ready after ${max_wait}s${NC}"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
        echo -n "."
    done
    echo ""
    echo -e "${GREEN}✓ Server is ready${NC}"

    # Send test request
    local start_time=$(date +%s.%N)
    local response=$(curl -sf -X POST "${url}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${model}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"What is 2+2? Answer in one word.\"}],
            \"max_tokens\": 10,
            \"temperature\": 0.0
        }" 2>/dev/null)
    local end_time=$(date +%s.%N)

    if [ -z "$response" ]; then
        echo -e "${RED}✗ Inference request failed${NC}"
        return 1
    fi

    # Parse response
    local tokens=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null || echo "0")
    local elapsed=$(echo "$end_time - $start_time" | bc -l)
    local tps=$(echo "scale=2; $tokens / $elapsed" | bc -l)

    echo -e "${GREEN}✓ Inference successful${NC}"
    echo -e "  Tokens: ${tokens}"
    echo -e "  Time: ${elapsed}s"
    echo -e "  ${BOLD}Throughput: ${tps} tokens/s${NC}"

    return 0
}

# Cleanup function
cleanup_container() {
    local container_name=$1
    echo -e "${CYAN}Cleaning up ${container_name}...${NC}"
    docker stop ${container_name} --time 10 2>/dev/null || true
    docker rm ${container_name} 2>/dev/null || true
}

################################################################################
# TEST 1: Single GPU, Small Model (SAFE)
################################################################################

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}TEST 1: Single GPU - Small Model (Llama-3.1-8B)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Risk Level: LOW${NC}"
echo -e "${CYAN}Goal: Verify GB10/SM120 basic compatibility${NC}"
echo ""

CONTAINER_NAME="trtllm-test-single"

# Cleanup any previous container
cleanup_container $CONTAINER_NAME

# Build docker run command
DOCKER_ARGS="--rm -d \
    --gpus '\"device=0\"' \
    --ipc host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    -p ${TEST_PORT}:8000 \
    -e TRTLLM_DISABLE_CUDAGRAPH=1 \
    ${TRTLLM_IMAGE} \
    trtllm-serve ${TEST_MODEL_SMALL}"

echo -e "${YELLOW}Configuration:${NC}"
echo -e "  Model: ${TEST_MODEL_SMALL}"
echo -e "  GPU: Single (device 0)"
echo -e "  CUDA Graphs: DISABLED (workaround for issue #8781)"
echo ""

if run_container_with_timeout $CONTAINER_NAME "$DOCKER_ARGS" $TIMEOUT_SECONDS; then
    echo -e "${GREEN}✓ Container started successfully${NC}"

    # Test inference
    if test_inference "http://localhost:${TEST_PORT}" "${TEST_MODEL_SMALL}"; then
        echo -e "${GREEN}✓✓✓ TEST 1 PASSED ✓✓✓${NC}"
        echo -e "${GREEN}GB10/SM120 basic support is working!${NC}"
        TEST1_PASSED=1
    else
        echo -e "${RED}✗✗✗ TEST 1 FAILED (Inference) ✗✗✗${NC}"
        TEST1_PASSED=0
    fi

    cleanup_container $CONTAINER_NAME
else
    echo -e "${RED}✗✗✗ TEST 1 FAILED (Container hang/crash) ✗✗✗${NC}"
    echo -e "${RED}GB10/SM120 support is broken in this TensorRT-LLM version${NC}"
    TEST1_PASSED=0
    cleanup_container $CONTAINER_NAME
    exit 1
fi

echo ""
sleep 3

################################################################################
# TEST 2: Single GPU with FP8 Quantization (MEDIUM RISK)
################################################################################

if [ "$TEST1_PASSED" -eq 1 ]; then
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}TEST 2: Single GPU - FP8 Quantization${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Risk Level: MEDIUM${NC}"
    echo -e "${CYAN}Goal: Test quantization support on GB10${NC}"
    echo ""

    CONTAINER_NAME="trtllm-test-fp8"

    cleanup_container $CONTAINER_NAME

    DOCKER_ARGS="--rm -d \
        --gpus '\"device=0\"' \
        --ipc host \
        --ulimit memlock=-1 \
        --ulimit stack=67108864 \
        -p ${TEST_PORT}:8000 \
        -e TRTLLM_DISABLE_CUDAGRAPH=1 \
        ${TRTLLM_IMAGE} \
        trtllm-serve ${TEST_MODEL_SMALL} --quantization FP8"

    echo -e "${YELLOW}Configuration:${NC}"
    echo -e "  Model: ${TEST_MODEL_SMALL}"
    echo -e "  Quantization: FP8"
    echo -e "  GPU: Single (device 0)"
    echo ""

    if run_container_with_timeout $CONTAINER_NAME "$DOCKER_ARGS" $TIMEOUT_SECONDS; then
        echo -e "${GREEN}✓ Container started successfully${NC}"

        if test_inference "http://localhost:${TEST_PORT}" "${TEST_MODEL_SMALL}"; then
            echo -e "${GREEN}✓✓✓ TEST 2 PASSED ✓✓✓${NC}"
            echo -e "${GREEN}FP8 quantization works on GB10!${NC}"
            TEST2_PASSED=1
        else
            echo -e "${RED}✗✗✗ TEST 2 FAILED (Inference) ✗✗✗${NC}"
            TEST2_PASSED=0
        fi

        cleanup_container $CONTAINER_NAME
    else
        echo -e "${RED}✗✗✗ TEST 2 FAILED (Container hang/crash) ✗✗✗${NC}"
        echo -e "${RED}FP8 quantization not working on GB10${NC}"
        TEST2_PASSED=0
        cleanup_container $CONTAINER_NAME
    fi

    echo ""
    sleep 3
else
    echo -e "${YELLOW}Skipping TEST 2 (TEST 1 failed)${NC}"
    TEST2_PASSED=0
fi

################################################################################
# TEST 3: Multi-Node Tensor Parallelism (HIGH RISK - DISABLED BY DEFAULT)
################################################################################

if [ "$ENABLE_MULTI_NODE_TEST" -eq 1 ]; then
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}TEST 3: Multi-Node Tensor Parallelism (TP=2)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${RED}⚠️⚠️⚠️  HIGH RISK - Known to cause system hangs ⚠️⚠️⚠️${NC}"
    echo -e "${RED}Issue #8781: CUDA graphs + AllReduce hangs${NC}"
    echo -e "${RED}Issue #2953: Multi-node memory corruption${NC}"
    echo ""
    echo -e "${YELLOW}Press Ctrl+C within 10 seconds to abort...${NC}"
    sleep 10

    echo -e "${RED}Not implemented - manual setup required${NC}"
    echo -e "${RED}Recommendation: Wait for TensorRT-LLM v1.2.0 final release${NC}"
    TEST3_PASSED=0
else
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}TEST 3: Multi-Node Tensor Parallelism (SKIPPED)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Multi-node testing DISABLED by default${NC}"
    echo -e "${YELLOW}    Known issues: #8781 (CUDA graph hangs), #2953 (memory corruption)${NC}"
    echo ""
    echo -e "${CYAN}To enable (NOT RECOMMENDED):${NC}"
    echo -e "  ENABLE_MULTI_NODE_TEST=1 ./test_tensorrt_llm_safe.sh"
    echo ""
    TEST3_PASSED=0
fi

################################################################################
# SUMMARY
################################################################################

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}TEST SUMMARY${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

if [ "$TEST1_PASSED" -eq 1 ]; then
    echo -e "${GREEN}✓ TEST 1: Single GPU (8B model)${NC}"
else
    echo -e "${RED}✗ TEST 1: Single GPU (8B model)${NC}"
fi

if [ "$TEST2_PASSED" -eq 1 ]; then
    echo -e "${GREEN}✓ TEST 2: FP8 Quantization${NC}"
else
    echo -e "${RED}✗ TEST 2: FP8 Quantization${NC}"
fi

if [ "$TEST3_PASSED" -eq 1 ]; then
    echo -e "${GREEN}✓ TEST 3: Multi-Node TP=2${NC}"
else
    echo -e "${YELLOW}⊘ TEST 3: Multi-Node TP=2 (skipped)${NC}"
fi

echo ""
echo -e "${BOLD}Recommendation:${NC}"

if [ "$TEST1_PASSED" -eq 1 ] && [ "$TEST2_PASSED" -eq 1 ]; then
    echo -e "${GREEN}✓ TensorRT-LLM works on single GPU with GB10${NC}"
    echo -e "${GREEN}  Use for: Llama-3.1-8B or smaller models${NC}"
    echo -e "${GREEN}  Expected performance: 2-3x faster than vLLM${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  For Llama-70B (requires 2 GPUs):${NC}"
    echo -e "${YELLOW}    Continue using vLLM until TensorRT-LLM v1.2.0 final${NC}"
elif [ "$TEST1_PASSED" -eq 1 ]; then
    echo -e "${YELLOW}⚠️  Basic support works, but quantization may be unstable${NC}"
    echo -e "${YELLOW}    Use TensorRT-LLM cautiously for single-GPU workloads${NC}"
else
    echo -e "${RED}✗ TensorRT-LLM NOT COMPATIBLE with GB10 in v1.2.0rc3${NC}"
    echo -e "${RED}  Recommendation: Continue using vLLM${NC}"
    echo -e "${RED}  Wait for: TensorRT-LLM v1.2.0 final or v1.3.0${NC}"
fi

echo ""
echo -e "${CYAN}For detailed analysis, see: TENSORRT_LLM_ANALYSIS.md${NC}"
echo ""

exit 0
