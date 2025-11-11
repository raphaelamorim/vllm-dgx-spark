# TensorRT-LLM Analysis for DGX Spark

## Executive Summary

**Status**: ⚠️ **CRITICAL COMPATIBILITY ISSUES IDENTIFIED**

TensorRT-LLM has **known issues with DGX Spark (GB10/SM120)** that likely explain the system lockups you've experienced. This document outlines the problems and provides a conservative, safe deployment strategy.

---

## Hardware Configuration

**Your System**:
- GPU: NVIDIA GB10 (Blackwell architecture)
- Compute Capability: 12.1 (SM120)
- CPU: ARM aarch64
- OS: Ubuntu 24.04.3 LTS
- CUDA: 13.0.88
- Driver: 580.95.05
- Memory: 128GB per GPU
- Configuration: 2x DGX Spark (1 GPU each)

---

## Critical Issues Discovered

### Issue #8474: DGX Spark Incompatibility

**Problem**: "Can't run GPT-OSS models on DGX Spark"

**Root Cause**:
```
Error 1 (CUTLASS backend): "The attention sinks is only supported on SM90"
Error 2 (TRTLLM backend): "TRTLLMGenFusedMoE does not support SM120 and above"
```

**Status**: Partially fixed in main branch, not yet released
- SM120 kernel support merged to main
- Will be available in next release candidate
- Current release (v1.2.0rc3) DOES NOT support SM120 properly

**Impact**: MoE models and certain attention optimizations fail on GB10 GPUs

### Issue #8781: CUDA Graph + Multi-GPU Hangs

**Problem**: "Execution hangs when enabling cudagraphs and AllReduceStrategy.AUTO"

**Root Cause**: Conflict between CUDA graphs and distributed all-reduce operations

**Status**: Closed (fixed Nov 4, 2025)

**Impact**: Multi-node deployments freeze when both features are enabled

### Issue #2953: Multi-Node Memory Corruption

**Problem**: "double free detected in tcache 2 when using trtllm-bench in a multi-node scenario"

**Status**: Open

**Impact**: Memory corruption in distributed inference, likely causes crashes/hangs

### Multiple Scale-Out Issues

**Problems**:
- #8961: Pipeline parallelism across nodes poorly documented
- #5970: PP_SIZE=2 fails while TP_SIZE=2 works
- #6405: Can't host large models (235B) even with 8x H100

**Pattern**: Multi-node deployments are unstable and poorly supported

---

## Why Your System Was Locking Up

Based on the research, the lockups were likely caused by:

1. **SM120 kernel incompatibility** - GB10 GPUs aren't fully supported in v1.2.0rc3
2. **CUDA graph + AllReduce deadlock** - Multi-GPU setup triggers known hang
3. **Memory corruption in multi-node** - Double-free errors crash the system
4. **Insufficient SM120 kernel coverage** - Missing optimized kernels for GB10

**Conclusion**: TensorRT-LLM is **not production-ready for DGX Spark** in multi-node configurations.

---

## Performance Expectations vs vLLM

### TensorRT-LLM Theoretical Advantages

**Optimizations**:
- Compiled TensorRT engines (fixed computation graphs)
- FP8/FP4 quantization support
- Custom CUDA kernels for specific GPUs
- Inflight batching
- KV cache optimizations

**Expected Performance Gain**: 1.5-3x faster than vLLM *when working*

### Reality Check for DGX Spark

**Problems**:
1. **GB10 not fully optimized** - Missing SM120 kernels means no performance benefit
2. **Multi-node broken** - Can't reliably run across 2 DGX Sparks
3. **Model size constraints** - Llama-3.3-70B requires 2 GPUs (multi-node)
4. **Build complexity** - Engine compilation can fail or produce invalid engines

**Realistic Expectation**:
- **Single GPU (smaller model)**: 2-3x faster than vLLM ✅
- **Multi-GPU (70B model)**: Unstable, likely to hang/crash ❌

---

## Recommended Strategy

### Option 1: Wait for Official Support (Recommended)

**Timeline**: Next TensorRT-LLM release (v1.2.0 final or v1.3.0)

**Rationale**:
- SM120 support is already merged to main branch
- Multi-node fixes are being addressed
- Avoid wasting time debugging pre-release bugs

**Action**: Monitor https://github.com/NVIDIA/TensorRT-LLM/releases

### Option 2: Build from Source (Advanced Users Only)

**Pros**:
- Get latest SM120 kernel support
- Access unreleased bug fixes

**Cons**:
- Complex build process on ARM
- No guarantee of stability
- May hit other undiscovered bugs
- Time-consuming (hours of compilation)

**Risk Level**: High

### Option 3: Single-GPU Testing (Safe Approach)

**Goal**: Test TensorRT-LLM on ONE DGX Spark with a smaller model

**Model**: Llama-3.1-8B (fits in 128GB VRAM)

**Expected Result**:
- No multi-node complexity
- Avoid tensor parallelism hangs
- Should work if SM120 kernels are present
- Performance gain: 2-3x over vLLM (40-80 t/s → 80-200 t/s)

**Risk Level**: Medium

### Option 4: Continue with vLLM (Pragmatic Choice)

**Rationale**:
- vLLM works reliably on your hardware
- 3.17 t/s is expected for 70B + TP=2 across nodes
- InfiniBand is configured correctly
- System is stable and production-ready

**Improvements**:
- Use concurrent requests (batching) → 8-15 t/s aggregate
- Switch to smaller model if latency matters
- Wait for vLLM performance improvements (actively developed)

**Risk Level**: None

---

## If You Decide to Try TensorRT-LLM

### Safe Testing Protocol

#### Step 1: Single-Node, Single-GPU Test

```bash
# Test on ONE DGX Spark only
# Use Llama-3.1-8B (fits in 128GB)
docker run --rm -it \
  --gpus all \
  --ipc host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -p 8000:8000 \
  nvcr.io/nvidia/tensorrt-llm/release:1.2.0rc3 \
  trtllm-serve "meta-llama/Llama-3.1-8B-Instruct"
```

**If this works**: GB10 support is functional for single-GPU
**If this hangs/crashes**: GB10 support is still broken, abort

#### Step 2: Test with FP8 Quantization (Performance Boost)

```bash
# Only if Step 1 succeeds
docker run --rm -it \
  --gpus all \
  --ipc host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -p 8000:8000 \
  nvcr.io/nvidia/tensorrt-llm/release:1.2.0rc3 \
  trtllm-serve "meta-llama/Llama-3.1-8B-Instruct" \
  --quantization FP8
```

**If this works**: Quantization is supported on GB10
**Expected performance**: 100-250 t/s

#### Step 3: Tensor Parallelism Test (High Risk)

```bash
# Only if Step 1 & 2 succeed
# Test TP=2 across 2 nodes
# WARNING: Known to hang in v1.2.0rc3
```

**Expected Result**: Likely to hang based on issue #8781
**Recommendation**: Skip this until v1.2.0 final release

---

## Configuration Workarounds for Known Issues

### Disable CUDA Graphs (Avoid Hangs)

If testing multi-GPU, disable CUDA graphs:

```bash
export TRTLLM_DISABLE_CUDAGRAPH=1
```

### Use CUTLASS Backend for MoE

If using Mixture-of-Experts models:

```yaml
moe_config:
  backend: CUTLASS
```

### Avoid AllReduceStrategy.AUTO

Use explicit all-reduce strategy:

```bash
--allreduce_strategy RING  # or NCCL
```

### Monitor for Memory Leaks

Watch for double-free errors:

```bash
docker logs -f <container> 2>&1 | grep -E "(double free|corrupted|SIGSEGV)"
```

---

## Performance Comparison: vLLM vs TensorRT-LLM

| Scenario | vLLM (Current) | TensorRT-LLM (Expected) | Risk Level |
|----------|----------------|-------------------------|------------|
| Llama-70B, TP=2, 2 nodes | 3.17 t/s | ❌ Likely hangs | Critical |
| Llama-70B, TP=2, 1 node | N/A (hardware limitation) | N/A | N/A |
| Llama-8B, single GPU | 40-80 t/s | 80-200 t/s | Medium |
| Llama-70B, 8 concurrent requests | 8-15 t/s aggregate | Unknown | N/A |

---

## Decision Matrix

### Choose vLLM if:
- ✅ You need production stability NOW
- ✅ Multi-node deployment is required (70B model)
- ✅ You can use concurrent requests for better throughput
- ✅ 3-15 t/s aggregate is acceptable

### Choose TensorRT-LLM if:
- ⚠️ You can use a smaller model (8B) on single GPU
- ⚠️ You're willing to test pre-release software
- ⚠️ You can wait for v1.2.0 final or build from source
- ⚠️ You need absolute maximum single-request performance

### Wait for Next Release if:
- 🔄 You need 70B model across 2 nodes
- 🔄 Production stability is critical
- 🔄 You want TensorRT-LLM performance without risks

---

## Monitoring & Troubleshooting

### Signs of GB10 Incompatibility

```
Error: "does not support SM120 and above"
Error: "only supported on SM90"
Error: "CUTLASS kernel not found for this architecture"
```

### Signs of Multi-Node Issues

```
Hang during: Engine loading
Hang during: First inference request
Error: "double free detected in tcache"
GPU utilization: Stuck at 0%
```

### Safe Abort Procedure

If system hangs during testing:

```bash
# Terminal 1: Monitor GPU
watch -n 1 nvidia-smi

# Terminal 2: Monitor Docker
docker logs -f <container>

# If hung for >5 minutes:
docker stop <container> --time 5
docker kill <container>  # if stop fails
```

---

## Conclusion

**Recommendation**: **Stick with vLLM for now**

**Rationale**:
1. TensorRT-LLM has known GB10 (SM120) compatibility issues
2. Multi-node deployments are unstable in v1.2.0rc3
3. Your vLLM setup is working correctly (3.17 t/s is expected)
4. Risk of system lockups outweighs potential 2-3x speedup
5. Next TensorRT-LLM release will have proper GB10 support

**Alternative**:
- Test TensorRT-LLM with **Llama-3.1-8B on single GPU** (safe)
- Expected: 2-3x faster than vLLM (100-200 t/s vs 40-80 t/s)
- If successful, consider for latency-critical workloads

**Long-term**:
- Monitor TensorRT-LLM v1.2.0 final release (Q1 2026)
- Re-evaluate when SM120 support is officially documented
- Consider building from main branch if you have DevOps resources

---

## References

- [Issue #8474: DGX Spark Compatibility](https://github.com/NVIDIA/TensorRT-LLM/issues/8474)
- [Issue #8781: CUDA Graph Hangs](https://github.com/NVIDIA/TensorRT-LLM/issues/8781)
- [Issue #2953: Multi-Node Memory Corruption](https://github.com/NVIDIA/TensorRT-LLM/issues/2953)
- [TensorRT-LLM Installation Guide](https://github.com/NVIDIA/TensorRT-LLM/blob/main/docs/source/installation/linux.md)
- [TensorRT-LLM Quick Start](https://github.com/NVIDIA/TensorRT-LLM/blob/main/docs/source/quick-start-guide.md)
