#!/bin/bash

################################################################################
# vLLM System Diagnostic Script for Multi-Node DGX Spark Cluster
#
# This script collects comprehensive diagnostic information about:
# - Ray cluster configuration and node connectivity
# - GPU visibility and utilization across all nodes
# - Network configuration (Ethernet vs InfiniBand)
# - NCCL communication topology
# - Docker container networking
#
# Output: vllm_diagnostic_report_<timestamp>.log
################################################################################

set -e

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Generate timestamp for log file
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="vllm_diagnostic_report_${TIMESTAMP}.log"

# Get the second DGX hostname from environment or prompt
SECOND_DGX="${SECOND_DGX_HOST:-}"

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}vLLM Multi-Node System Diagnostic${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo -e "Log file: ${GREEN}${LOG_FILE}${NC}"
echo ""

# Function to write section headers
write_header() {
    local title="$1"
    echo "" | tee -a "$LOG_FILE"
    echo "================================================================================" | tee -a "$LOG_FILE"
    echo "  $title" | tee -a "$LOG_FILE"
    echo "================================================================================" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

# Function to run command and log output
run_command() {
    local description="$1"
    local command="$2"
    local ignore_errors="${3:-false}"

    echo -e "${YELLOW}>>> ${description}${NC}"
    echo ">>> ${description}" >> "$LOG_FILE"
    echo "Command: ${command}" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"

    if [ "$ignore_errors" = "true" ]; then
        eval "$command" >> "$LOG_FILE" 2>&1 || echo "Warning: Command failed (non-critical)" >> "$LOG_FILE"
    else
        if eval "$command" >> "$LOG_FILE" 2>&1; then
            echo -e "${GREEN}✓ Success${NC}"
        else
            echo -e "${RED}✗ Failed${NC}"
            echo "ERROR: Command failed" >> "$LOG_FILE"
        fi
    fi
    echo "" >> "$LOG_FILE"
}

# Start diagnostic report
{
    echo "vLLM Multi-Node Diagnostic Report"
    echo "Generated: $(date)"
    echo "Hostname: $(hostname)"
    echo "User: $(whoami)"
    echo ""
} > "$LOG_FILE"

# Check if second DGX hostname is configured
if [ -z "$SECOND_DGX" ]; then
    echo -e "${YELLOW}Warning: SECOND_DGX_HOST not set. Some multi-node checks will be skipped.${NC}"
    echo -e "To enable full diagnostics, set: ${GREEN}export SECOND_DGX_HOST=<hostname>${NC}"
    echo ""
    echo "SECOND_DGX_HOST not configured - some multi-node checks skipped" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
else
    echo -e "Second DGX configured: ${GREEN}${SECOND_DGX}${NC}"
    echo ""
    echo "Second DGX Host: ${SECOND_DGX}" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
fi

################################################################################
# 1. SYSTEM INFORMATION
################################################################################
write_header "1. SYSTEM INFORMATION"

run_command "Operating System Information" "cat /etc/os-release"
run_command "Kernel Version" "uname -a"
run_command "Current Date/Time" "date"
run_command "Uptime" "uptime"
run_command "Available Memory" "free -h"
run_command "CPU Information" "lscpu | grep -E 'Model name|Socket|Core|Thread'"

################################################################################
# 2. GPU CONFIGURATION - LOCAL NODE
################################################################################
write_header "2. GPU CONFIGURATION - LOCAL NODE ($(hostname))"

run_command "NVIDIA Driver Version" "nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1"
run_command "GPU List" "nvidia-smi -L"
run_command "GPU Status Summary" "nvidia-smi --query-gpu=index,name,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu --format=csv"
run_command "GPU Topology Matrix" "nvidia-smi topo -m"
run_command "Detailed GPU Information" "nvidia-smi"

################################################################################
# 3. GPU CONFIGURATION - REMOTE NODE (if configured)
################################################################################
if [ -n "$SECOND_DGX" ]; then
    write_header "3. GPU CONFIGURATION - REMOTE NODE (${SECOND_DGX})"

    run_command "Remote GPU List" "ssh ${SECOND_DGX} 'nvidia-smi -L'" true
    run_command "Remote GPU Status Summary" "ssh ${SECOND_DGX} 'nvidia-smi --query-gpu=index,name,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu --format=csv'" true
    run_command "Remote GPU Topology Matrix" "ssh ${SECOND_DGX} 'nvidia-smi topo -m'" true
    run_command "Remote Detailed GPU Information" "ssh ${SECOND_DGX} 'nvidia-smi'" true
fi

################################################################################
# 4. DOCKER CONFIGURATION
################################################################################
write_header "4. DOCKER CONFIGURATION"

run_command "Docker Version" "docker --version"
run_command "Running Containers" "docker ps"
run_command "All Containers (including stopped)" "docker ps -a"

# Check if ray-head container exists
if docker ps -a --format '{{.Names}}' | grep -q '^ray-head$'; then
    run_command "Ray-Head Container Inspection" "docker inspect ray-head"
    run_command "Ray-Head Network Settings" "docker inspect ray-head | grep -A 30 'NetworkSettings'"
    run_command "Ray-Head Environment Variables" "docker exec ray-head env | sort"
    run_command "GPUs Visible in Ray-Head Container" "docker exec ray-head nvidia-smi -L" true
else
    echo "ray-head container not found - skipping container checks" | tee -a "$LOG_FILE"
fi

################################################################################
# 5. RAY CLUSTER STATUS
################################################################################
write_header "5. RAY CLUSTER STATUS"

if docker ps --format '{{.Names}}' | grep -q '^ray-head$'; then
    run_command "Ray Cluster Status" "docker exec ray-head bash -c 'export RAY_ADDRESS=127.0.0.1:6379; ray status'" true
    run_command "Ray Cluster Status (Verbose)" "docker exec ray-head bash -c 'export RAY_ADDRESS=127.0.0.1:6379; ray status --verbose'" true
    run_command "Ray Node Information (Python)" "docker exec ray-head bash -c 'export RAY_ADDRESS=127.0.0.1:6379; python3 -c \"import ray; ray.init(address=\\\"127.0.0.1:6379\\\"); import json; print(json.dumps(ray.nodes(), indent=2))\"'" true
    run_command "Ray Available Resources" "docker exec ray-head bash -c 'export RAY_ADDRESS=127.0.0.1:6379; python3 -c \"import ray; ray.init(address=\\\"127.0.0.1:6379\\\"); print(ray.available_resources())\"'" true
else
    echo "ray-head container not running - skipping Ray checks" | tee -a "$LOG_FILE"
fi

################################################################################
# 6. NETWORK CONFIGURATION - LOCAL NODE
################################################################################
write_header "6. NETWORK CONFIGURATION - LOCAL NODE"

run_command "Network Interfaces" "ip addr show"
run_command "Network Routes" "ip route show"
run_command "InfiniBand Status" "ibstat" true
run_command "InfiniBand Device Status" "ibstatus" true
run_command "InfiniBand Kernel Modules" "lsmod | grep -E '^ib_|^rdma|^mlx'" true
run_command "RDMA Devices" "ls -la /dev/infiniband/" true
run_command "Network Interface Statistics" "ip -s link"

################################################################################
# 7. NETWORK CONFIGURATION - REMOTE NODE (if configured)
################################################################################
if [ -n "$SECOND_DGX" ]; then
    write_header "7. NETWORK CONFIGURATION - REMOTE NODE"

    run_command "Remote Network Interfaces" "ssh ${SECOND_DGX} 'ip addr show'" true
    run_command "Remote InfiniBand Status" "ssh ${SECOND_DGX} 'ibstat'" true
    run_command "Remote InfiniBand Device Status" "ssh ${SECOND_DGX} 'ibstatus'" true
    run_command "Remote InfiniBand Kernel Modules" "ssh ${SECOND_DGX} 'lsmod | grep -E \"^ib_|^rdma|^mlx\"'" true

    run_command "Network Connectivity Test (ping)" "ping -c 4 ${SECOND_DGX}" true
fi

################################################################################
# 8. NCCL CONFIGURATION
################################################################################
write_header "8. NCCL CONFIGURATION"

if docker ps --format '{{.Names}}' | grep -q '^ray-head$'; then
    run_command "NCCL Environment Variables in Container" "docker exec ray-head bash -c 'env | grep -E \"NCCL|UCX|GLOO\" | sort'" true
    run_command "NCCL/CUDA Libraries in Container" "docker exec ray-head bash -c 'ldconfig -p | grep -E \"nccl|cuda\"'" true
else
    echo "ray-head container not running - skipping NCCL container checks" | tee -a "$LOG_FILE"
fi

run_command "NCCL Libraries on Host" "ldconfig -p | grep nccl" true

################################################################################
# 9. VLLM PROCESS INFORMATION
################################################################################
write_header "9. VLLM PROCESS INFORMATION"

run_command "vLLM Processes" "ps aux | grep -E 'vllm|ray::' | grep -v grep" true

if docker ps --format '{{.Names}}' | grep -q '^ray-head$'; then
    run_command "vLLM Processes in Container" "docker exec ray-head bash -c 'ps aux | grep vllm | grep -v grep'" true
    run_command "Ray Processes in Container" "docker exec ray-head bash -c 'ps aux | grep ray | grep -v grep'" true
fi

################################################################################
# 10. DOCKER LOGS (Recent)
################################################################################
write_header "10. DOCKER LOGS (Last 100 lines)"

if docker ps -a --format '{{.Names}}' | grep -q '^ray-head$'; then
    run_command "Ray-Head Container Logs (tail)" "docker logs ray-head --tail 100" true
else
    echo "ray-head container not found - skipping log checks" | tee -a "$LOG_FILE"
fi

################################################################################
# 11. SYSTEM RESOURCE USAGE
################################################################################
write_header "11. SYSTEM RESOURCE USAGE"

run_command "Disk Usage" "df -h"
run_command "Top Processes by CPU" "ps aux --sort=-%cpu | head -20"
run_command "Top Processes by Memory" "ps aux --sort=-%mem | head -20"

################################################################################
# SUMMARY
################################################################################
write_header "DIAGNOSTIC SUMMARY"

{
    echo "Summary of Key Findings:"
    echo ""

    # Count GPUs
    GPU_COUNT=$(nvidia-smi -L | wc -l)
    echo "- Local GPUs detected: ${GPU_COUNT}"

    if [ -n "$SECOND_DGX" ]; then
        REMOTE_GPU_COUNT=$(ssh ${SECOND_DGX} 'nvidia-smi -L 2>/dev/null | wc -l' || echo "0")
        echo "- Remote GPUs detected: ${REMOTE_GPU_COUNT}"
        echo "- Total GPUs in cluster: $((GPU_COUNT + REMOTE_GPU_COUNT))"
    fi

    # Check Ray status
    if docker ps --format '{{.Names}}' | grep -q '^ray-head$'; then
        RAY_NODES=$(docker exec ray-head bash -c 'export RAY_ADDRESS=127.0.0.1:6379; ray status 2>/dev/null | grep -c "node_" || echo "0"' 2>/dev/null || echo "0")
        echo "- Ray nodes connected: ${RAY_NODES}"
    fi

    # Check InfiniBand
    if ibstat >/dev/null 2>&1; then
        IB_STATUS=$(ibstat 2>/dev/null | grep -c "State: Active" || echo "0")
        echo "- InfiniBand ports active: ${IB_STATUS}"
    else
        echo "- InfiniBand: Not detected or not available"
    fi

    echo ""
    echo "Full diagnostic log saved to: ${LOG_FILE}"

} | tee -a "$LOG_FILE"

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Diagnostic Complete!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "Report saved to: ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Review the log file for any errors or warnings"
echo "2. Share this log file for detailed analysis"
echo "3. Check the SUMMARY section at the end of the log"
echo ""

if [ -z "$SECOND_DGX" ]; then
    echo -e "${YELLOW}Tip: Set SECOND_DGX_HOST environment variable for full multi-node diagnostics:${NC}"
    echo -e "  ${GREEN}export SECOND_DGX_HOST=<second-dgx-hostname>${NC}"
    echo -e "  ${GREEN}./vllm_system_checkout.sh${NC}"
    echo ""
fi

exit 0
