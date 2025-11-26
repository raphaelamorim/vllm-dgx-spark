#!/usr/bin/env bash
set -euo pipefail

################################################################################
# vLLM Model Benchmark Script
#
# Comprehensive benchmark for any model currently loaded in vLLM.
# Auto-detects the model and runs latency, throughput, concurrent, and
# streaming performance tests.
#
# Usage:
#   ./benchmark_current_vllm.sh [options]
#
# Options:
#   -u, --url URL        vLLM API URL (default: auto-detect)
#   -n, --requests N     Number of test requests per benchmark (default: 5)
#   -c, --concurrency N  Number of concurrent requests (default: 5)
#   -o, --output FILE    Output results to JSON file
#   -q, --quick          Quick mode: fewer requests, faster results
#   -v, --verbose        Show response content in output
#   -h, --help           Show this help message
#
# Examples:
#   ./benchmark_current_vllm.sh
#   ./benchmark_current_vllm.sh -u http://192.168.6.64:8000
#   ./benchmark_current_vllm.sh -n 10 -c 8 -o results.json
#   ./benchmark_current_vllm.sh --quick
################################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Default configuration
API_URL=""
NUM_REQUESTS=5
CONCURRENCY=5
OUTPUT_FILE=""
QUICK_MODE=false
VERBOSE=false
MODEL=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--url)
      API_URL="$2"
      shift 2
      ;;
    -n|--requests)
      NUM_REQUESTS="$2"
      shift 2
      ;;
    -c|--concurrency)
      CONCURRENCY="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -q|--quick)
      QUICK_MODE=true
      NUM_REQUESTS=3
      CONCURRENCY=3
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      head -28 "$0" | tail -23
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Auto-detect API URL if not provided
if [ -z "$API_URL" ]; then
  # Try localhost first
  if curl -sf "http://localhost:8000/health" >/dev/null 2>&1; then
    API_URL="http://localhost:8000"
  else
    # Try to detect from network interfaces
    PUBLIC_IP=$(ip -o addr show | grep "inet " | grep -v "127.0.0.1" | grep -v "169.254" | grep -v "172.17" | awk '{print $4}' | cut -d'/' -f1 | head -1)
    if [ -n "$PUBLIC_IP" ] && curl -sf "http://${PUBLIC_IP}:8000/health" >/dev/null 2>&1; then
      API_URL="http://${PUBLIC_IP}:8000"
    else
      API_URL="http://localhost:8000"
    fi
  fi
fi

# Set output file with timestamp if specified but empty
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Temporary directory for benchmark data
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

################################################################################
# Helper Functions
################################################################################

print_header() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_subheader() {
  echo ""
  echo -e "${CYAN}▶ $1${NC}"
  echo ""
}

check_dependencies() {
  local missing=()

  for cmd in curl python3 bc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}Missing required dependencies: ${missing[*]}${NC}"
    echo "Install with: apt-get install -y curl python3 bc"
    exit 1
  fi
}

check_vllm() {
  echo -e "${YELLOW}Checking vLLM availability...${NC}"

  if ! curl -sf "${API_URL}/health" >/dev/null 2>&1; then
    echo -e "${RED}Error: vLLM is not accessible at ${API_URL}${NC}"
    echo -e "${RED}Make sure vLLM is running: ./start_head_vllm.sh${NC}"
    exit 1
  fi

  # Get model name from API
  MODEL=$(curl -sf "${API_URL}/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")

  if [ "$MODEL" = "unknown" ]; then
    echo -e "${RED}Error: Could not detect model from vLLM API${NC}"
    exit 1
  fi

  echo -e "${GREEN}✓ vLLM is accessible${NC}"
  echo -e "${GREEN}✓ Model: ${MODEL}${NC}"

  # Detect if this is a reasoning model by checking for reasoning_content in a test response
  local test_response=$(curl -sf -X POST "${API_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"${MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}], \"max_tokens\": 50}" 2>/dev/null)

  if echo "$test_response" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['choices'][0]['message'].get('reasoning_content') else 1)" 2>/dev/null; then
    echo -e "${GREEN}✓ Reasoning model detected (uses reasoning_content)${NC}"
  fi
}

# Make a single API request and return metrics
# Supports both standard models and reasoning models (e.g., DeepSeek R1)
# Reasoning models may return content in reasoning_content field
make_request() {
  local prompt="$1"
  local max_tokens="$2"
  local output_file="$3"

  local start_time=$(date +%s.%N)

  # Write response to temp file to avoid heredoc escaping issues
  local response_file="${output_file}.response"
  curl -sf -X POST "${API_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}],
      \"max_tokens\": ${max_tokens},
      \"temperature\": 0.7
    }" > "$response_file" 2>/dev/null

  local end_time=$(date +%s.%N)

  if [ ! -s "$response_file" ]; then
    echo '{"success": false, "error": "request_failed"}' > "$output_file"
    rm -f "$response_file"
    return 1
  fi

  # Parse response and calculate metrics
  # Handles reasoning models where content may be null but reasoning_content exists
  python3 << EOF > "$output_file"
import json
import sys

start = ${start_time}
end = ${end_time}

try:
    with open("${response_file}", "r") as f:
        data = json.load(f)

    elapsed = end - start
    completion_tokens = data["usage"]["completion_tokens"]

    # Check if we got any output (content or reasoning_content for reasoning models)
    message = data["choices"][0]["message"]
    content = message.get("content")
    reasoning_content = message.get("reasoning_content")

    # For reasoning models, accept response if we have reasoning_content even if content is null
    has_output = content is not None or reasoning_content is not None

    if not has_output:
        print(json.dumps({"success": False, "error": "no_content_generated"}))
    else:
        result = {
            "success": True,
            "prompt_tokens": data["usage"]["prompt_tokens"],
            "completion_tokens": completion_tokens,
            "total_tokens": data["usage"]["total_tokens"],
            "elapsed_seconds": round(elapsed, 3),
            "tokens_per_second": round(completion_tokens / elapsed, 2) if elapsed > 0 else 0,
            "is_reasoning_model": reasoning_content is not None
        }
        print(json.dumps(result))
except Exception as e:
    print(json.dumps({"success": False, "error": str(e)}))
EOF

  rm -f "$response_file"
}

################################################################################
# Benchmark Tests
################################################################################

run_latency_test() {
  print_subheader "Test 1: Latency (Short Generation)"
  echo "  Measuring response latency with minimal token generation..."
  echo ""

  local total_latency=0
  local min_latency=999999
  local max_latency=0
  local success_count=0

  for i in $(seq 1 $NUM_REQUESTS); do
    printf "  Request %d/%d... " "$i" "$NUM_REQUESTS"

    make_request "Hello, respond briefly." 100 "$TMP_DIR/latency_$i.json"

    local result=$(cat "$TMP_DIR/latency_$i.json")
    local success=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))")

    if [ "$success" = "True" ]; then
      local latency=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['elapsed_seconds'])")
      echo -e "${GREEN}${latency}s${NC}"

      total_latency=$(echo "$total_latency + $latency" | bc -l)
      success_count=$((success_count + 1))

      # Track min/max
      if (( $(echo "$latency < $min_latency" | bc -l) )); then
        min_latency=$latency
      fi
      if (( $(echo "$latency > $max_latency" | bc -l) )); then
        max_latency=$latency
      fi
    else
      echo -e "${RED}failed${NC}"
    fi

    sleep 0.5
  done

  echo ""
  if [ $success_count -gt 0 ]; then
    local avg_latency=$(echo "scale=3; $total_latency / $success_count" | bc -l)
    echo -e "  ${BOLD}Results:${NC}"
    echo -e "    Average: ${GREEN}${avg_latency}s${NC}"
    echo -e "    Min:     ${min_latency}s"
    echo -e "    Max:     ${max_latency}s"

    # Save summary
    echo "{\"test\": \"latency\", \"avg_seconds\": $avg_latency, \"min_seconds\": $min_latency, \"max_seconds\": $max_latency, \"requests\": $success_count}" > "$TMP_DIR/summary_latency.json"
  fi
}

run_throughput_test() {
  print_subheader "Test 2: Single Request Throughput"
  echo "  Measuring tokens/second for individual requests..."
  echo ""

  local prompts=(
    "Explain the concept of artificial intelligence in detail."
    "Describe how modern computers process information."
    "Write about the history of the internet and its impact."
    "Explain the basics of quantum computing technology."
    "Describe the process of machine learning model training."
  )

  local total_tokens=0
  local total_time=0
  local success_count=0
  local all_tps=""

  for i in $(seq 1 $NUM_REQUESTS); do
    local prompt_idx=$(( (i - 1) % ${#prompts[@]} ))
    local prompt="${prompts[$prompt_idx]}"

    printf "  Request %d/%d (256 tokens)... " "$i" "$NUM_REQUESTS"

    make_request "$prompt" 256 "$TMP_DIR/throughput_$i.json"

    local result=$(cat "$TMP_DIR/throughput_$i.json")
    local success=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))")

    if [ "$success" = "True" ]; then
      local tokens=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['completion_tokens'])")
      local elapsed=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['elapsed_seconds'])")
      local tps=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['tokens_per_second'])")

      echo -e "${GREEN}${tokens} tokens, ${tps} t/s${NC}"

      total_tokens=$((total_tokens + tokens))
      total_time=$(echo "$total_time + $elapsed" | bc -l)
      success_count=$((success_count + 1))
      all_tps="$all_tps $tps"
    else
      echo -e "${RED}failed${NC}"
    fi

    sleep 0.5
  done

  echo ""
  if [ $success_count -gt 0 ]; then
    local avg_tps=$(echo "scale=2; $total_tokens / $total_time" | bc -l)
    echo -e "  ${BOLD}Results:${NC}"
    echo -e "    Total tokens:      ${total_tokens}"
    echo -e "    Total time:        ${total_time}s"
    echo -e "    Average throughput: ${GREEN}${avg_tps} tokens/second${NC}"

    echo "{\"test\": \"throughput\", \"avg_tokens_per_second\": $avg_tps, \"total_tokens\": $total_tokens, \"total_seconds\": $total_time, \"requests\": $success_count}" > "$TMP_DIR/summary_throughput.json"
  fi
}

run_concurrent_test() {
  print_subheader "Test 3: Concurrent Request Performance"
  echo "  Testing ${CONCURRENCY} parallel requests..."
  echo ""

  local start_time=$(date +%s.%N)

  # Launch concurrent requests
  for i in $(seq 1 $CONCURRENCY); do
    (
      make_request "Write a detailed paragraph about technology topic number $i and its applications." 256 "$TMP_DIR/concurrent_$i.json"
    ) &
  done

  # Wait for all to complete
  wait

  local end_time=$(date +%s.%N)
  local wall_time=$(echo "$end_time - $start_time" | bc -l)

  # Aggregate results
  local total_tokens=0
  local success_count=0

  for i in $(seq 1 $CONCURRENCY); do
    local result=$(cat "$TMP_DIR/concurrent_$i.json" 2>/dev/null || echo '{"success": false}')
    local success=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))")

    if [ "$success" = "True" ]; then
      local tokens=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['completion_tokens'])")
      total_tokens=$((total_tokens + tokens))
      success_count=$((success_count + 1))
      echo -e "  Request $i: ${GREEN}${tokens} tokens${NC}"
    else
      echo -e "  Request $i: ${RED}failed${NC}"
    fi
  done

  echo ""
  if [ $success_count -gt 0 ]; then
    local aggregate_tps=$(echo "scale=2; $total_tokens / $wall_time" | bc -l)
    local wall_time_rounded=$(echo "scale=2; $wall_time / 1" | bc)

    echo -e "  ${BOLD}Results:${NC}"
    echo -e "    Successful:         ${success_count}/${CONCURRENCY}"
    echo -e "    Total tokens:       ${total_tokens}"
    echo -e "    Wall time:          ${wall_time_rounded}s"
    echo -e "    Aggregate throughput: ${GREEN}${aggregate_tps} tokens/second${NC}"

    echo "{\"test\": \"concurrent\", \"concurrency\": $CONCURRENCY, \"aggregate_tokens_per_second\": $aggregate_tps, \"total_tokens\": $total_tokens, \"wall_seconds\": $wall_time_rounded, \"successful\": $success_count}" > "$TMP_DIR/summary_concurrent.json"
  fi
}

run_long_generation_test() {
  print_subheader "Test 4: Long Generation Performance"
  echo "  Testing sustained generation with 512 tokens..."
  echo ""

  local iterations=3
  if [ "$QUICK_MODE" = true ]; then
    iterations=2
  fi

  local total_tokens=0
  local total_time=0
  local success_count=0

  for i in $(seq 1 $iterations); do
    printf "  Request %d/%d (512 tokens)... " "$i" "$iterations"

    make_request "Write a comprehensive essay about the future of technology, covering artificial intelligence, quantum computing, biotechnology, and space exploration. Include potential benefits and challenges for society." 512 "$TMP_DIR/long_$i.json"

    local result=$(cat "$TMP_DIR/long_$i.json")
    local success=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))")

    if [ "$success" = "True" ]; then
      local tokens=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['completion_tokens'])")
      local elapsed=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['elapsed_seconds'])")
      local tps=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['tokens_per_second'])")

      echo -e "${GREEN}${tokens} tokens, ${tps} t/s${NC}"

      total_tokens=$((total_tokens + tokens))
      total_time=$(echo "$total_time + $elapsed" | bc -l)
      success_count=$((success_count + 1))
    else
      echo -e "${RED}failed${NC}"
    fi
  done

  echo ""
  if [ $success_count -gt 0 ]; then
    local avg_tps=$(echo "scale=2; $total_tokens / $total_time" | bc -l)
    echo -e "  ${BOLD}Results:${NC}"
    echo -e "    Total tokens:      ${total_tokens}"
    echo -e "    Average throughput: ${GREEN}${avg_tps} tokens/second${NC}"

    echo "{\"test\": \"long_generation\", \"avg_tokens_per_second\": $avg_tps, \"total_tokens\": $total_tokens, \"requests\": $success_count}" > "$TMP_DIR/summary_long.json"
  fi
}

run_streaming_test() {
  print_subheader "Test 5: Streaming Performance"
  echo "  Measuring time to first token with streaming..."
  echo ""

  local start_time=$(date +%s.%N)
  local first_token_time=""
  local token_count=0
  local ttft=""

  # Capture streaming output
  timeout 60 curl -sf "${API_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Write a short story about exploration.\"}],
      \"max_tokens\": 200,
      \"stream\": true
    }" 2>/dev/null | while IFS= read -r line; do

    if [[ "$line" == data:* ]]; then
      local json_data="${line#data: }"
      if [[ "$json_data" != "[DONE]" ]]; then
        local content=$(echo "$json_data" | python3 -c 'import sys,json; data=json.load(sys.stdin); print(data["choices"][0]["delta"].get("content", ""))' 2>/dev/null || echo "")
        if [ -n "$content" ]; then
          token_count=$((token_count + 1))
          if [ $token_count -eq 1 ]; then
            first_token_time=$(date +%s.%N)
            ttft=$(echo "$first_token_time - $start_time" | bc -l)
            echo "  First token received at: ${ttft}s"
          fi
          if [ "$VERBOSE" = true ]; then
            echo -n "$content"
          fi
        fi
      fi
    fi
  done || true

  local end_time=$(date +%s.%N)
  local total_time=$(echo "$end_time - $start_time" | bc -l)
  local total_time_rounded=$(echo "scale=2; $total_time / 1" | bc)

  echo ""
  echo -e "  ${BOLD}Results:${NC}"
  echo -e "    Total streaming time: ${total_time_rounded}s"

  echo "{\"test\": \"streaming\", \"total_seconds\": $total_time_rounded}" > "$TMP_DIR/summary_streaming.json"
}

run_multi_domain_test() {
  print_subheader "Test 6: Multi-Domain Performance"
  echo "  Testing performance across different content types..."
  echo ""

  local domains=("code" "math" "creative" "technical" "general")
  local prompts=(
    "Write a Python function to sort a list of numbers"
    "Solve: What is the derivative of x^3 + 2x^2 - 5x + 3?"
    "Write a short poem about the ocean"
    "Explain how TCP/IP networking works"
    "What are the main causes of climate change?"
  )

  local total_time=0
  local total_tokens=0

  for i in {0..4}; do
    local domain="${domains[$i]}"
    local prompt="${prompts[$i]}"

    printf "  %-10s " "${domain}:"

    make_request "$prompt" 256 "$TMP_DIR/domain_$i.json"

    local result=$(cat "$TMP_DIR/domain_$i.json")
    local success=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))")

    if [ "$success" = "True" ]; then
      local tokens=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['completion_tokens'])")
      local elapsed=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['elapsed_seconds'])")
      local tps=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['tokens_per_second'])")

      echo -e "${GREEN}${tokens} tokens, ${tps} t/s${NC}"

      total_tokens=$((total_tokens + tokens))
      total_time=$(echo "$total_time + $elapsed" | bc -l)
    else
      echo -e "${RED}failed${NC}"
    fi
  done

  echo ""
  if (( $(echo "$total_time > 0" | bc -l) )); then
    local avg_tps=$(echo "scale=2; $total_tokens / $total_time" | bc -l)
    echo -e "  ${BOLD}Results:${NC}"
    echo -e "    Total tokens:       ${total_tokens}"
    echo -e "    Average throughput: ${GREEN}${avg_tps} tokens/second${NC}"

    echo "{\"test\": \"multi_domain\", \"avg_tokens_per_second\": $avg_tps, \"total_tokens\": $total_tokens}" > "$TMP_DIR/summary_domain.json"
  fi
}

################################################################################
# Summary and Output
################################################################################

generate_summary() {
  print_header "Benchmark Summary"
  echo ""
  echo -e "  ${BOLD}Model:${NC}     ${MODEL}"
  echo -e "  ${BOLD}API URL:${NC}   ${API_URL}"
  echo -e "  ${BOLD}Timestamp:${NC} $(date)"
  echo ""

  # Collect results
  echo -e "  ${BOLD}Results:${NC}"

  local throughput_tps=0

  if [ -f "$TMP_DIR/summary_latency.json" ]; then
    local latency=$(python3 -c "import json; print(json.load(open('$TMP_DIR/summary_latency.json'))['avg_seconds'])")
    echo -e "    Latency (avg):          ${GREEN}${latency}s${NC}"
  fi

  if [ -f "$TMP_DIR/summary_throughput.json" ]; then
    throughput_tps=$(python3 -c "import json; print(json.load(open('$TMP_DIR/summary_throughput.json'))['avg_tokens_per_second'])")
    echo -e "    Single throughput:      ${GREEN}${throughput_tps} t/s${NC}"
  fi

  if [ -f "$TMP_DIR/summary_concurrent.json" ]; then
    local conc_tps=$(python3 -c "import json; print(json.load(open('$TMP_DIR/summary_concurrent.json'))['aggregate_tokens_per_second'])")
    echo -e "    Concurrent throughput:  ${GREEN}${conc_tps} t/s${NC}"
  fi

  if [ -f "$TMP_DIR/summary_long.json" ]; then
    local long_tps=$(python3 -c "import json; print(json.load(open('$TMP_DIR/summary_long.json'))['avg_tokens_per_second'])")
    echo -e "    Long gen throughput:    ${GREEN}${long_tps} t/s${NC}"
  fi

  if [ -f "$TMP_DIR/summary_domain.json" ]; then
    local domain_tps=$(python3 -c "import json; print(json.load(open('$TMP_DIR/summary_domain.json'))['avg_tokens_per_second'])")
    echo -e "    Multi-domain avg:       ${GREEN}${domain_tps} t/s${NC}"
  fi

  echo ""

  # Performance assessment
  echo -e "  ${BOLD}Performance Assessment:${NC}"
  if (( $(echo "$throughput_tps > 0" | bc -l) )); then
    if (( $(echo "$throughput_tps < 10" | bc -l) )); then
      echo -e "    ${RED}⚠ Very low throughput (<10 t/s)${NC}"
      echo -e "    ${YELLOW}  - Check InfiniBand/RoCE configuration${NC}"
      echo -e "    ${YELLOW}  - Run: docker exec ray-head tail -50 /var/log/vllm.log | grep NCCL${NC}"
    elif (( $(echo "$throughput_tps < 30" | bc -l) )); then
      echo -e "    ${YELLOW}⚠ Moderate throughput (<30 t/s)${NC}"
      echo -e "    ${YELLOW}  - Consider increasing GPU memory utilization${NC}"
    elif (( $(echo "$throughput_tps >= 50" | bc -l) )); then
      echo -e "    ${GREEN}✓ Excellent throughput (${throughput_tps} t/s)${NC}"
    else
      echo -e "    ${GREEN}✓ Good throughput (${throughput_tps} t/s)${NC}"
    fi
  fi

  # Save JSON output if requested
  if [ -n "$OUTPUT_FILE" ]; then
    python3 << EOF > "$OUTPUT_FILE"
import json
import glob
import os

results = {
    "model": "${MODEL}",
    "api_url": "${API_URL}",
    "timestamp": "$(date -Iseconds)",
    "config": {
        "num_requests": ${NUM_REQUESTS},
        "concurrency": ${CONCURRENCY},
        "quick_mode": ${QUICK_MODE}
    },
    "tests": {}
}

for f in glob.glob("${TMP_DIR}/summary_*.json"):
    try:
        with open(f) as fp:
            data = json.load(fp)
            test_name = data.pop("test", os.path.basename(f).replace("summary_", "").replace(".json", ""))
            results["tests"][test_name] = data
    except:
        pass

print(json.dumps(results, indent=2))
EOF
    echo ""
    echo -e "  ${GREEN}✓ Results saved to: ${CYAN}${OUTPUT_FILE}${NC}"
  fi

  echo ""
  echo -e "  ${GREEN}✓ Benchmark complete!${NC}"
}

################################################################################
# Main
################################################################################

main() {
  print_header "vLLM Model Benchmark"
  echo ""
  echo -e "  API URL:     ${CYAN}${API_URL}${NC}"
  echo -e "  Requests:    ${CYAN}${NUM_REQUESTS}${NC}"
  echo -e "  Concurrency: ${CYAN}${CONCURRENCY}${NC}"
  if [ "$QUICK_MODE" = true ]; then
    echo -e "  Mode:        ${CYAN}Quick${NC}"
  fi
  echo ""

  check_dependencies
  check_vllm

  # Run all benchmark tests
  run_latency_test
  run_throughput_test
  run_concurrent_test
  run_long_generation_test
  run_streaming_test

  if [ "$QUICK_MODE" = false ]; then
    run_multi_domain_test
  fi

  generate_summary

  print_header "Done"
  echo ""
}

main "$@"
