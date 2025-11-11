#!/bin/bash

################################################################################
# vLLM Token/Second Benchmark Script
#
# This script tests the actual tokens per second throughput of a running
# vLLM instance with various prompt lengths and generation sizes.
#
# Usage:
#   ./benchmark_tokens_per_second.sh [vllm_url] [model_name]
#
# Examples:
#   ./benchmark_tokens_per_second.sh
#   ./benchmark_tokens_per_second.sh http://localhost:8000
#   ./benchmark_tokens_per_second.sh http://192.168.1.100:8000 "meta-llama/Llama-3.3-70B-Instruct"
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
VLLM_URL="${1:-http://localhost:8000}"
MODEL_NAME="${2:-}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_FILE="benchmark_results_${TIMESTAMP}.txt"

# Benchmark parameters
WARMUP_REQUESTS=2
TEST_REQUESTS=5

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}vLLM Tokens/Second Benchmark${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo -e "vLLM URL: ${CYAN}${VLLM_URL}${NC}"
echo -e "Results will be saved to: ${CYAN}${RESULTS_FILE}${NC}"
echo ""

# Initialize results file
{
    echo "vLLM Token/Second Benchmark Results"
    echo "Generated: $(date)"
    echo "vLLM URL: ${VLLM_URL}"
    echo "Model: ${MODEL_NAME:-auto-detected}"
    echo ""
} > "$RESULTS_FILE"

# Function to check if vLLM is accessible
check_vllm() {
    echo -e "${YELLOW}Checking vLLM availability...${NC}"
    if ! curl -sf "${VLLM_URL}/health" >/dev/null 2>&1; then
        echo -e "${RED}✗ Error: vLLM is not accessible at ${VLLM_URL}${NC}"
        echo -e "${RED}  Make sure vLLM is running and the URL is correct${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ vLLM is accessible${NC}"
    echo ""
}

# Function to get model name
get_model_name() {
    if [ -z "$MODEL_NAME" ]; then
        echo -e "${YELLOW}Auto-detecting model name...${NC}"
        MODEL_NAME=$(curl -sf "${VLLM_URL}/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")
        echo -e "${GREEN}✓ Model: ${MODEL_NAME}${NC}"
        echo ""
    fi
}

# Function to run a single benchmark test
run_benchmark() {
    local test_name="$1"
    local prompt="$2"
    local max_tokens="$3"
    local num_requests="$4"

    echo -e "${BOLD}Test: ${test_name}${NC}"
    echo -e "  Prompt length: ~${#prompt} characters"
    echo -e "  Max tokens: ${max_tokens}"
    echo -e "  Requests: ${num_requests}"
    echo ""

    # Write test header to results file
    {
        echo "================================================================"
        echo "Test: ${test_name}"
        echo "Prompt length: ~${#prompt} characters"
        echo "Max tokens: ${max_tokens}"
        echo "Requests: ${num_requests}"
        echo "================================================================"
        echo ""
    } >> "$RESULTS_FILE"

    local total_tokens=0
    local total_time=0
    local success_count=0

    for i in $(seq 1 "$num_requests"); do
        echo -e "${CYAN}  Request ${i}/${num_requests}...${NC}"

        # Prepare request
        local request_data=$(cat <<EOF
{
  "model": "${MODEL_NAME}",
  "messages": [
    {"role": "user", "content": "${prompt}"}
  ],
  "max_tokens": ${max_tokens},
  "temperature": 0.7
}
EOF
)

        # Make request and time it
        local start_time=$(date +%s.%N)
        local response=$(curl -sf -X POST "${VLLM_URL}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$request_data" 2>/dev/null)
        local end_time=$(date +%s.%N)

        if [ -z "$response" ]; then
            echo -e "${RED}    ✗ Request failed${NC}"
            continue
        fi

        # Parse response
        local completion_tokens=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null || echo "0")
        local prompt_tokens=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['prompt_tokens'])" 2>/dev/null || echo "0")

        if [ "$completion_tokens" -eq 0 ]; then
            echo -e "${RED}    ✗ Failed to parse response${NC}"
            continue
        fi

        # Calculate metrics
        local elapsed=$(echo "$end_time - $start_time" | bc -l)
        local tokens_per_second=$(echo "scale=2; $completion_tokens / $elapsed" | bc -l)

        # Accumulate totals
        total_tokens=$((total_tokens + completion_tokens))
        total_time=$(echo "$total_time + $elapsed" | bc -l)
        success_count=$((success_count + 1))

        # Display results
        echo -e "${GREEN}    ✓ Generated ${completion_tokens} tokens in ${elapsed}s${NC}"
        echo -e "      ${BOLD}Throughput: ${tokens_per_second} tokens/second${NC}"
        echo -e "      Prompt tokens: ${prompt_tokens}"

        # Write to results file
        {
            echo "Request ${i}:"
            echo "  Completion tokens: ${completion_tokens}"
            echo "  Prompt tokens: ${prompt_tokens}"
            echo "  Time: ${elapsed}s"
            echo "  Throughput: ${tokens_per_second} tokens/s"
            echo ""
        } >> "$RESULTS_FILE"

        # Small delay between requests
        sleep 1
    done

    # Calculate and display averages
    if [ "$success_count" -gt 0 ]; then
        local avg_tokens_per_second=$(echo "scale=2; $total_tokens / $total_time" | bc -l)
        local avg_time=$(echo "scale=2; $total_time / $success_count" | bc -l)
        local avg_tokens=$(echo "scale=0; $total_tokens / $success_count" | bc -l)

        echo ""
        echo -e "${BOLD}${GREEN}Summary:${NC}"
        echo -e "  Successful requests: ${success_count}/${num_requests}"
        echo -e "  Total tokens generated: ${total_tokens}"
        echo -e "  Total time: ${total_time}s"
        echo -e "  ${BOLD}Average throughput: ${avg_tokens_per_second} tokens/second${NC}"
        echo -e "  Average tokens per request: ${avg_tokens}"
        echo -e "  Average time per request: ${avg_time}s"

        # Write summary to results file
        {
            echo "Summary:"
            echo "  Successful requests: ${success_count}/${num_requests}"
            echo "  Total tokens generated: ${total_tokens}"
            echo "  Total time: ${total_time}s"
            echo "  Average throughput: ${avg_tokens_per_second} tokens/s"
            echo "  Average tokens per request: ${avg_tokens}"
            echo "  Average time per request: ${avg_time}s"
            echo ""
        } >> "$RESULTS_FILE"

        # Return average throughput for overall summary
        echo "$avg_tokens_per_second"
    else
        echo -e "${RED}All requests failed!${NC}"
        echo "0"
    fi

    echo ""
}

# Main benchmark execution
main() {
    check_vllm
    get_model_name

    echo -e "${BOLD}Starting benchmark...${NC}"
    echo ""

    # Array to store results for final summary
    declare -a test_results

    # Warm-up
    echo -e "${YELLOW}Warm-up phase (${WARMUP_REQUESTS} requests)...${NC}"
    run_benchmark "Warm-up" "Hello, how are you?" 50 "$WARMUP_REQUESTS" > /dev/null
    echo -e "${GREEN}✓ Warm-up complete${NC}"
    echo ""
    sleep 2

    # Test 1: Short prompt, short generation
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}Test 1: Short Prompt, Short Generation${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""
    result=$(run_benchmark \
        "Short Prompt, Short Generation" \
        "What is the capital of France?" \
        100 \
        "$TEST_REQUESTS")
    test_results+=("Short/Short: $result t/s")

    # Test 2: Short prompt, medium generation
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}Test 2: Short Prompt, Medium Generation${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""
    result=$(run_benchmark \
        "Short Prompt, Medium Generation" \
        "Explain the theory of relativity in simple terms." \
        300 \
        "$TEST_REQUESTS")
    test_results+=("Short/Medium: $result t/s")

    # Test 3: Short prompt, long generation
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}Test 3: Short Prompt, Long Generation${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""
    result=$(run_benchmark \
        "Short Prompt, Long Generation" \
        "Write a detailed story about space exploration." \
        500 \
        "$TEST_REQUESTS")
    test_results+=("Short/Long: $result t/s")

    # Test 4: Medium prompt, medium generation
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}Test 4: Medium Prompt, Medium Generation${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""
    medium_prompt="You are a helpful AI assistant. I need help understanding how neural networks work. Please explain the basic concepts of neural networks, including neurons, layers, weights, biases, activation functions, and backpropagation. Make it easy to understand for someone with basic programming knowledge."
    result=$(run_benchmark \
        "Medium Prompt, Medium Generation" \
        "$medium_prompt" \
        400 \
        "$TEST_REQUESTS")
    test_results+=("Medium/Medium: $result t/s")

    # Test 5: Long prompt, short generation
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}Test 5: Long Prompt, Short Generation${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""
    long_prompt="Context: You are analyzing a complex software system. The system consists of multiple microservices including authentication service, user management service, data processing service, notification service, and API gateway. Each service is containerized using Docker and orchestrated with Kubernetes. The authentication service uses JWT tokens, the data processing service handles large datasets using Apache Spark, and the notification service integrates with multiple third-party APIs. Based on this context, answer the following question: What are the main security considerations?"
    result=$(run_benchmark \
        "Long Prompt, Short Generation" \
        "$long_prompt" \
        150 \
        "$TEST_REQUESTS")
    test_results+=("Long/Short: $result t/s")

    # Final Summary
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BOLD}${GREEN}FINAL BENCHMARK SUMMARY${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo ""
    echo -e "${BOLD}Model:${NC} ${MODEL_NAME}"
    echo -e "${BOLD}vLLM URL:${NC} ${VLLM_URL}"
    echo ""
    echo -e "${BOLD}Results:${NC}"
    for result in "${test_results[@]}"; do
        echo -e "  ${result}"
    done
    echo ""

    # Write final summary to results file
    {
        echo ""
        echo "================================================================"
        echo "FINAL SUMMARY"
        echo "================================================================"
        echo ""
        echo "Model: ${MODEL_NAME}"
        echo "vLLM URL: ${VLLM_URL}"
        echo ""
        echo "Results:"
        for result in "${test_results[@]}"; do
            echo "  ${result}"
        done
        echo ""
        echo "Test completed at: $(date)"
    } >> "$RESULTS_FILE"

    echo -e "${GREEN}✓ Benchmark complete!${NC}"
    echo -e "Detailed results saved to: ${CYAN}${RESULTS_FILE}${NC}"
    echo ""

    # Performance analysis
    echo -e "${BOLD}Performance Analysis:${NC}"

    # Extract the first numerical throughput value for analysis
    first_throughput=$(echo "${test_results[0]}" | grep -oP '\d+\.\d+' || echo "0")

    if (( $(echo "$first_throughput < 10" | bc -l) )); then
        echo -e "${RED}⚠️  WARNING: Very low throughput detected (<10 t/s)${NC}"
        echo -e "   Possible issues:"
        echo -e "   - InfiniBand/RoCE not being used (check with: ./check_infiniband.sh)"
        echo -e "   - Network bottleneck (verify NCCL is using NET/IB)"
        echo -e "   - Run diagnostics: ./vllm_system_checkout.sh"
    elif (( $(echo "$first_throughput < 30" | bc -l) )); then
        echo -e "${YELLOW}⚠️  Low throughput detected (<30 t/s)${NC}"
        echo -e "   Consider:"
        echo -e "   - Increasing GPU memory utilization"
        echo -e "   - Verifying all GPUs are being used"
        echo -e "   - Checking network configuration"
    elif (( $(echo "$first_throughput >= 50" | bc -l) )); then
        echo -e "${GREEN}✓ Excellent throughput! InfiniBand/RoCE is working well.${NC}"
    else
        echo -e "${GREEN}✓ Good throughput for this configuration.${NC}"
    fi
    echo ""
}

# Run main function
main

exit 0
