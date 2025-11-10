# Troubleshooting Guide

## Issue: Head Node Stuck at "Step 8/8: Starting vLLM server"

### Symptoms
The script hangs after showing:
```
[2025-11-05 18:39:46] Step 8/8: Starting vLLM server
```

### Diagnosis Steps

1. **Check vLLM logs to see what's happening:**
```bash
docker exec ray-head tail -100 /var/log/vllm.log
```

2. **Check if vLLM process is running:**
```bash
docker exec ray-head ps aux | grep vllm
```

3. **Check container logs:**
```bash
docker logs ray-head --tail 50
```

### Common Causes

#### 1. Model Download Still in Progress
Even though Step 7 says "Model download complete", vLLM may still be downloading/loading the model.

**Solution:**
```bash
# Watch the vLLM logs in real-time
docker exec ray-head tail -f /var/log/vllm.log
```

Wait for messages indicating model is loaded. For a 70B model, this can take 5-10 minutes.

#### 2. Insufficient GPU Memory
The model may be too large for available GPU memory.

**Solution:**
```bash
# Check GPU memory usage
nvidia-smi

# If memory is tight, reduce memory utilization or context length
export GPU_MEMORY_UTIL="0.60"  # Lower from 0.70
export MAX_MODEL_LEN="1024"    # Lower from 2048

# Then restart the head script
bash start_head_vllm.sh
```

#### 3. Ray Cluster Not Ready
Ray may not be fully initialized.

**Solution:**
```bash
# Check Ray status
docker exec ray-head ray status --address=127.0.0.1:6379

# If issues, restart Ray
docker exec ray-head bash -c "ray stop --force && ray start --head --port=6379 --dashboard-host=0.0.0.0 --dashboard-port=8265"
```

#### 4. Port 8000 Already in Use

**Solution:**
```bash
# Check if something is using port 8000
sudo netstat -tulpn | grep 8000

# Kill old vLLM processes
docker exec ray-head pkill -f vllm
```

### Manual vLLM Startup

If the script continues to hang, you can start vLLM manually:

```bash
# Stop the script (Ctrl+C)

# Start vLLM manually in foreground to see output
docker exec -it ray-head bash -c "
export HF_HOME=/root/.cache/huggingface
export RAY_ADDRESS=127.0.0.1:6379
export VLLM_LOGGING_LEVEL=INFO

vllm serve meta-llama/Llama-3.3-70B-Instruct \
  --distributed-executor-backend ray \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 2 \
  --max-model-len 2048 \
  --gpu-memory-utilization 0.70 \
  --enforce-eager
"
```

Watch for errors in the output.

---

## Issue: Worker Shows "may not be connected after 30s"

### Symptoms
```
[2025-11-05 18:41:28] ⚠️ Worker may not be connected after 30s
```

But then shows "Worker is ready!"

### This is Usually Not a Problem

The warning appears if the worker doesn't respond within 30 seconds, but the worker script continues anyway. If it shows "Worker is ready!" at the end, the worker likely connected successfully.

### Verify Worker Connection

From the head node:
```bash
docker exec ray-head ray status --address=127.0.0.1:6379
```

Expected output should show:
```
Resources
---------------------------------------------------------------
 ...
 Healthy:
    192.168.100.10 (node_xxx)
    192.168.100.11 (node_yyy)  # <- Should show 2 nodes
```

If only 1 node shows, the worker is NOT connected.

### Solutions

1. **Check network connectivity from worker to head:**
```bash
# On worker node
ping 192.168.100.10
nc -zv 192.168.100.10 6379
```

2. **Check Ray ports are open:**
```bash
# On head node
sudo firewall-cmd --list-all
# Or on Ubuntu
sudo ufw status
```

Ray needs these ports:
- 6379 (GCS)
- 8265 (Dashboard)
- 10001-10100 (Object store)

3. **Check worker Ray logs:**
```bash
docker logs ray-worker-spark-xxxx | tail -50
```

4. **Manually restart worker connection:**
```bash
docker exec ray-worker-spark-xxxx bash -c "
ray stop --force
ray start --address=192.168.100.10:6379 --node-ip-address=192.168.100.11
"
```

---

## CRITICAL: You Are Using Ethernet IP Instead of InfiniBand!

### Your Configuration Shows
```
Head IP: 192.168.100.10
```

### This is WRONG for DGX Spark

DGX Spark requires InfiniBand IPs (169.254.x.x range) for proper performance.

**Using Ethernet IPs will result in 10-20x slower performance!**

### Fix This Issue

1. **Find your InfiniBand IPs on each node:**

On head node:
```bash
ip addr show | grep 169.254
```

Expected output:
```
inet 169.254.x.x/16 brd 169.254.255.255 scope global enp1s0f1np1
```

On worker node:
```bash
ip addr show | grep 169.254
```

Expected output:
```
inet 169.254.y.y/16 brd 169.254.255.255 scope global enp1s0f1np1
```

2. **Verify InfiniBand is working:**
```bash
ibstatus
```

Should show:
```
Infiniband device 'mlx5_0' port 1 status:
    state: 4: ACTIVE
    physical state: 5: LinkUp
```

3. **Test InfiniBand connectivity:**

From head:
```bash
ping 169.254.y.y  # Worker IB IP
```

From worker:
```bash
ping 169.254.x.x  # Head IB IP
```

4. **Reconfigure and restart with correct IPs:**

On head node:
```bash
# Stop and remove old containers
docker stop ray-head
docker rm ray-head

# Set correct InfiniBand IP
export HEAD_IP="169.254.x.x"  # Replace with YOUR InfiniBand IP
export MODEL="meta-llama/Llama-3.3-70B-Instruct"
export HF_TOKEN="your_token_here"

# Restart head script
bash start_head_vllm.sh
```

On worker node:
```bash
# Stop and remove old containers
docker stop ray-worker-spark-xxxx
docker rm ray-worker-spark-xxxx

# Set correct InfiniBand IPs
export HEAD_IP="169.254.x.x"     # Head InfiniBand IP
export WORKER_IP="169.254.y.y"    # Worker InfiniBand IP

# Restart worker script
bash start_worker_vllm.sh
```

### Why InfiniBand Matters

- **InfiniBand**: 200 Gb/s bandwidth
- **Ethernet**: 1-10 Gb/s bandwidth

For distributed inference with tensor parallelism across two nodes, you **MUST** use InfiniBand for acceptable performance.

---

## Health Check Script

After fixing the InfiniBand IPs and restarting, run the test script:

```bash
# Set the correct InfiniBand IP
export HEAD_IP="169.254.x.x"

bash test_vllm_cluster.sh
```

This will verify:
- Container status
- Ray cluster health (should show 2 nodes)
- vLLM health endpoint
- Model availability
- Actual inference test
- GPU utilization
- Network connectivity

---

## Getting More Help

If issues persist:

1. **Collect diagnostic information:**
```bash
# Ray status
docker exec ray-head ray status --address=127.0.0.1:6379

# vLLM logs
docker exec ray-head tail -100 /var/log/vllm.log

# Container logs
docker logs ray-head --tail 100
docker logs ray-worker-spark-xxxx --tail 100

# GPU status
nvidia-smi

# Network status
ip addr show
ibstatus
```

2. **Check NVIDIA's InfiniBand setup guide:**
https://build.nvidia.com/spark/nccl/stacked-sparks

3. **Open an issue on GitHub with the diagnostic output**
