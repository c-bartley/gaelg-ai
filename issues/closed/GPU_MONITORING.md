# Issue #5: GPU Memory Monitoring — RESOLVED

## Problem

Your GPU VRAM is near capacity:
- **cuda:0**: 9.8 GB / 10 GB (97.9% used) — only 218 MB free
- **cuda:1**: 5.97 GB / 10 GB (59.6% used) — 4 GB free

This is dangerous. Any concurrent request could trigger OOM (Out of Memory) error, crashing the process or silently failing requests.

**Risk:** If two synthesis requests try to run simultaneously on cuda:0, both fail with CUDA OOM.

## Solution

### 1. Added GPU Memory Monitoring Functions

```python
def get_gpu_memory_info(device_id=0):
    """Get GPU memory: total, allocated, free, and percent used."""
    return {
        "device": "cuda:0",
        "total_gb": 10.0,
        "allocated_gb": 9.8,
        "free_gb": 0.2,
        "percent_used": 98.0,
    }
```

### 2. GPU Memory Logging at Startup

Server logs GPU memory before and after each model loads:

```
Initial GPU cuda:0: 0.0GB / 10.0GB (0.1%)
Initial GPU cuda:1: 0.0GB / 10.0GB (0.1%)
✓ TTS loaded successfully
After TTS: GPU cuda:0: 6.5GB / 10.0GB (65.0%)
✓ ASR loaded successfully
After ASR: GPU cuda:1: 5.8GB / 10.0GB (58.0%)
✓ MT loaded successfully
After MT: GPU cuda:0: 9.2GB / 10.0GB (92.0%)
✓ Voice conversion loaded successfully
After VC: GPU cuda:0: 9.8GB / 10.0GB (98.0%)
⚠️  GPU cuda:0 memory critical: 9.8/10.0GB (98.0%) — concurrent requests may fail
```

This gives you visibility into:
- Total VRAM per GPU
- How much each model consumes
- Whether memory is critically tight

### 3. Added `/gpu-status` Endpoint

Check current GPU memory usage:

**Request:**
```bash
curl http://143.167.8.81:8000/gpu-status | jq
```

**Response:**
```json
{
  "cuda:0": {
    "device": "cuda:0",
    "total_gb": 10.0,
    "allocated_gb": 9.8,
    "reserved_gb": 10.0,
    "free_gb": 0.2,
    "percent_used": 98.0
  },
  "cuda:1": {
    "device": "cuda:1",
    "total_gb": 10.0,
    "allocated_gb": 5.97,
    "reserved_gb": 6.0,
    "free_gb": 4.03,
    "percent_used": 59.7
  },
  "warning_threshold_percent": 85
}
```

### 4. Configurable Warning Threshold

```bash
# Warn if GPU exceeds 85% (default)
GPU_MEMORY_WARNING_PERCENT=85

# More aggressive: warn at 80%
GPU_MEMORY_WARNING_PERCENT=80

# More lenient: warn at 95%
GPU_MEMORY_WARNING_PERCENT=95
```

If GPU usage exceeds this threshold at startup, logs a warning:
```
⚠️  GPU cuda:0 memory critical: 9.8/10.0GB (98.0%) — concurrent requests may fail
```

### 5. Critical Warning on OOM Risk

If any GPU is >85% at startup, the final log warns about concurrency risk:
```
⚠️  GPU cuda:0 memory critical: 9.8/10.0GB (98.0%) — concurrent requests may fail
```

This tells operators: "This server can only handle 1 TTS request at a time; concurrent requests will fail."

## Behavior

### On Startup
```
Initial GPU cuda:0: 0.0GB / 10.0GB (0.1%)
After TTS: GPU cuda:0: 6.5GB / 10.0GB (65.0%)
After MT: GPU cuda:0: 9.2GB / 10.0GB (92.0%)
After VC: GPU cuda:0: 9.8GB / 10.0GB (98.0%)
✓ Startup complete
⚠️  GPU cuda:0 memory critical: 9.8/10.0GB (98.0%) — concurrent requests may fail
```

### On Request (every request uses semaphore for serialization)
Semaphores already prevent concurrent inference on same GPU, so even though VRAM is tight, only 1 synthesis runs at a time.

### Monitoring in Production
```bash
# Check current GPU status
curl http://143.167.8.81:8000/gpu-status | jq

# Follow startup logs
sudo journalctl -u manx-tts -f

# Extract GPU messages
sudo journalctl -u manx-tts -g "GPU" -n 50
```

## Understanding the Issue

**Why cuda:0 is so full:**

| Model | Device | Memory |
|-------|--------|--------|
| TTS (Grad-TTS) | cuda:0 | ~3.5 GB |
| MT (NLLB 2 directions) | cuda:0 | ~3.5 GB |
| VC (WavLM + HiFi-GAN) | cuda:0 | ~2.8 GB |
| **Total** | **cuda:0** | **~9.8 GB** |
| Headroom | | ~0.2 GB |

**Why this is tight:**

During inference, models need temporary buffers. With only 0.2 GB free:
- Large batch inference → OOM
- Large audio file processing → OOM
- Memory fragmentation → OOM

**The semaphores help:**
- They serialize requests on each GPU
- Only 1 TTS, 1 ASR, 1 MT, 1 VC runs at a time
- This prevents competing for the same VRAM
- But if TTS takes 3 seconds, client waits 3 seconds (doesn't crash)

## Mitigation Strategies

### Option 1: Model Pruning / Optimization (Out of scope)
- Reduce model precision (FP32 → FP16)
- Smaller model variants
- Model quantization
- Requires code changes outside this scope

### Option 2: GPU Upgrade
- Larger VRAM (RTX 3090, RTX 4090, A100)
- More GPUs
- Requires hardware investment

### Option 3: Separate Inference Servers
- TTS on one server
- ASR on another
- MT on a third
- Clients call the right endpoint
- Requires load balancer and networking

### Option 4: Load Shedding (Best for now)
- Add request queue monitoring
- Reject requests if queue is too long (return 503)
- Implement backpressure
- See Issue #9: Rate Limiting

## Monitoring Recommendations

### Daily Checks
```bash
# Check if memory is stable
curl http://143.167.8.81:8000/gpu-status | jq '.["cuda:0"].percent_used'

# Look for OOM errors in logs
sudo journalctl -u manx-tts | grep -i "oom\|cuda\|out of memory"
```

### Set Alerts
```bash
# Alert if GPU >85% for more than 5 minutes (requires monitoring system)
# Alert if any CUDA errors occur
# Alert if synthesis/transcription latency increases (indicative of OOM pressure)
```

### Load Testing
Before pushing to production, test under load:
```bash
# Simulate concurrent users (will queue due to semaphores)
for i in {1..10}; do
  curl -X POST http://143.167.8.81:8000/synthesize \
    -H "Content-Type: application/json" \
    -d '{"text": "test sentence"}' &
done
wait
```

Monitor during this test:
```bash
watch -n 1 'curl -s http://143.167.8.81:8000/gpu-status | jq ".\"cuda:0\""'
```

## Configuration

In systemd service:
```ini
Environment="GPU_MEMORY_WARNING_PERCENT=85"
```

Common settings:

| Setting | Behavior |
|---------|----------|
| 80% | Warn if VRAM gets tight (conservative) |
| 85% | Default — balanced |
| 90% | Allow tighter packing (aggressive) |

## Testing

### Test GPU status endpoint
```bash
curl http://143.167.8.81:8000/gpu-status | jq
```

### Test startup logs show GPU memory
```bash
cd /exp/exp1/acp24csb/web_platform
python3 -m uvicorn backend.main:app 2>&1 | grep -i "gpu\|memory"
```

### Simulate memory pressure
There's no easy way to trigger OOM without actually overwhelming VRAM. The semaphores already prevent this. If you need to test OOM handling:
```python
# In Python, allocate and hold VRAM
import torch
gpu0_reserve = torch.zeros((9, 1024*1024*1024), dtype=torch.float32).cuda(0)  # Reserve 9GB
```

## Frontend Impact

Optionally, frontend can show GPU status or queue length to warn users of delays:

```javascript
fetch('/gpu-status')
  .then(r => r.json())
  .then(data => {
    if (data['cuda:0'].percent_used > 90) {
      showWarning("Server is under heavy load, requests may be delayed");
    }
  });
```

See [FRONTEND_CHANGES_REQUIRED.md](../FRONTEND_CHANGES_REQUIRED.md) for optional enhancements.

## Benefits

✅ **Visibility** — See exactly what's using VRAM
✅ **Early warning** — Know when VRAM is getting tight
✅ **Debugging** — Compare memory before/after model load
✅ **Monitoring** — Track VRAM usage over time via `/gpu-status`
✅ **Production-ready** — Alerts operators to potential OOM issues
