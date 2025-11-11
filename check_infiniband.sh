#!/bin/bash

################################################################################
# InfiniBand Diagnostic Script for DGX Spark
#
# This script checks InfiniBand connectivity and configuration
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}InfiniBand Diagnostic Check${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# 1. Check for InfiniBand hardware
echo -e "${YELLOW}1. Checking for InfiniBand Hardware...${NC}"
if lspci | grep -i mellanox > /dev/null 2>&1; then
    echo -e "${GREEN}✓ InfiniBand hardware detected:${NC}"
    lspci | grep -i mellanox
else
    echo -e "${RED}✗ No Mellanox InfiniBand hardware found${NC}"
fi
echo ""

# 2. Check if IB tools are installed
echo -e "${YELLOW}2. Checking InfiniBand Tools Installation...${NC}"
if command -v ibstat > /dev/null 2>&1; then
    echo -e "${GREEN}✓ ibstat is installed${NC}"
else
    echo -e "${RED}✗ ibstat is NOT installed${NC}"
    echo -e "  Install with: ${GREEN}sudo apt-get install infiniband-diags${NC}"
fi

if command -v ibstatus > /dev/null 2>&1; then
    echo -e "${GREEN}✓ ibstatus is installed${NC}"
else
    echo -e "${RED}✗ ibstatus is NOT installed${NC}"
fi
echo ""

# 3. Check IB kernel modules
echo -e "${YELLOW}3. Checking InfiniBand Kernel Modules...${NC}"
IB_MODULES=$(lsmod | grep -E '^ib_|^rdma|^mlx')
if [ -n "$IB_MODULES" ]; then
    echo -e "${GREEN}✓ InfiniBand kernel modules loaded:${NC}"
    echo "$IB_MODULES"
else
    echo -e "${RED}✗ No InfiniBand kernel modules loaded${NC}"
fi
echo ""

# 4. Check IB devices
echo -e "${YELLOW}4. Checking InfiniBand Devices...${NC}"
if [ -d /dev/infiniband ]; then
    echo -e "${GREEN}✓ InfiniBand devices found:${NC}"
    ls -la /dev/infiniband/
else
    echo -e "${RED}✗ No InfiniBand devices at /dev/infiniband/${NC}"
fi
echo ""

# 5. Check network interfaces
echo -e "${YELLOW}5. Checking Network Interfaces...${NC}"
echo "Looking for InfiniBand interfaces (ib0, ib1, etc.):"
if ip addr show | grep -E '^[0-9]+: ib' > /dev/null 2>&1; then
    echo -e "${GREEN}✓ InfiniBand network interfaces found:${NC}"
    ip addr show | grep -E '^[0-9]+: ib' -A 5
else
    echo -e "${RED}✗ No InfiniBand network interfaces found${NC}"
    echo "Available interfaces:"
    ip addr show | grep -E '^[0-9]+:' | awk '{print "  " $2}'
fi
echo ""

# 6. Check IB status (if tools are installed)
echo -e "${YELLOW}6. Checking InfiniBand Port Status...${NC}"
if command -v ibstat > /dev/null 2>&1; then
    ibstat 2>&1
else
    echo -e "${YELLOW}⚠ Skipping (ibstat not installed)${NC}"
fi
echo ""

# 7. Check if NCCL environment variables are set
echo -e "${YELLOW}7. Checking NCCL InfiniBand Configuration...${NC}"
if [ -n "$NCCL_IB_DISABLE" ]; then
    if [ "$NCCL_IB_DISABLE" = "1" ]; then
        echo -e "${RED}✗ NCCL_IB_DISABLE=1 (InfiniBand is DISABLED!)${NC}"
    else
        echo -e "${GREEN}✓ NCCL_IB_DISABLE=$NCCL_IB_DISABLE${NC}"
    fi
else
    echo -e "${YELLOW}⚠ NCCL_IB_DISABLE not set (may default to auto-detect)${NC}"
fi

if [ -n "$NCCL_SOCKET_IFNAME" ]; then
    echo -e "  NCCL_SOCKET_IFNAME=${NCCL_SOCKET_IFNAME}"
else
    echo -e "${YELLOW}⚠ NCCL_SOCKET_IFNAME not set${NC}"
fi

if [ -n "$NCCL_IB_HCA" ]; then
    echo -e "  NCCL_IB_HCA=${NCCL_IB_HCA}"
else
    echo -e "${YELLOW}⚠ NCCL_IB_HCA not set${NC}"
fi
echo ""

# 8. Check NCCL environment in Ray container
echo -e "${YELLOW}8. Checking NCCL Configuration in Ray Container...${NC}"
if docker ps --format '{{.Names}}' | grep -q '^ray-head$'; then
    echo "NCCL environment variables in ray-head container:"
    docker exec ray-head bash -c 'env | grep -E "NCCL|UCX" | sort' 2>&1 || echo "  (none found)"
else
    echo -e "${YELLOW}⚠ ray-head container not running${NC}"
fi
echo ""

# 9. Summary
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}SUMMARY${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

HAS_HARDWARE=$(lspci | grep -i mellanox > /dev/null 2>&1 && echo "yes" || echo "no")
HAS_TOOLS=$(command -v ibstat > /dev/null 2>&1 && echo "yes" || echo "no")
HAS_DEVICES=$([ -d /dev/infiniband ] && echo "yes" || echo "no")
HAS_INTERFACE=$(ip addr show | grep -E '^[0-9]+: ib' > /dev/null 2>&1 && echo "yes" || echo "no")

echo "InfiniBand Hardware Present: $HAS_HARDWARE"
echo "InfiniBand Tools Installed: $HAS_TOOLS"
echo "InfiniBand Devices Present: $HAS_DEVICES"
echo "InfiniBand Network Interface: $HAS_INTERFACE"
echo ""

if [ "$HAS_HARDWARE" = "yes" ] && [ "$HAS_INTERFACE" = "yes" ]; then
    echo -e "${GREEN}✓ InfiniBand appears to be available${NC}"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    if [ "$HAS_TOOLS" = "no" ]; then
        echo "1. Install IB tools: sudo apt-get install infiniband-diags"
    fi
    echo "2. Configure NCCL to use InfiniBand (see recommendations below)"
    echo "3. Test IB bandwidth with ib_write_bw"
elif [ "$HAS_HARDWARE" = "yes" ]; then
    echo -e "${YELLOW}⚠ InfiniBand hardware present but network interface not configured${NC}"
    echo ""
    echo "Possible issues:"
    echo "- InfiniBand drivers not properly installed"
    echo "- Network interface not brought up"
    echo "- InfiniBand subnet manager not running"
else
    echo -e "${RED}✗ No InfiniBand hardware detected${NC}"
    echo ""
    echo "This may indicate:"
    echo "- Wrong PCI slot"
    echo "- Hardware not enabled in BIOS"
    echo "- Driver issues"
fi

echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}RECOMMENDED NCCL CONFIGURATION${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo "Add these to your vLLM startup script:"
echo ""
echo -e "${GREEN}export NCCL_IB_DISABLE=0${NC}              # Enable InfiniBand"
echo -e "${GREEN}export NCCL_IB_HCA=mlx5${NC}               # Use Mellanox HCA"
echo -e "${GREEN}export NCCL_SOCKET_IFNAME=ib0${NC}         # Use ib0 interface"
echo -e "${GREEN}export NCCL_DEBUG=INFO${NC}                # Enable debug logging"
echo -e "${GREEN}export NCCL_DEBUG_SUBSYS=INIT,NET${NC}     # Debug network initialization"
echo ""

exit 0
