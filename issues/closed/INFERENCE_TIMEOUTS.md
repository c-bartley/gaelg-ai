# Issue #6: Inference Timeouts — RESOLVED

## Problem

Model inference operations had **no timeout**. If a GPU operation hung or became infinitely slow:
- Request would block indefinitely
- Client would hang indefinitely
- Server would accumulate blocked requests
- Eventually server would become unresponsive

**Examples of when this could happen:**
- GPU memory corruption → hung kernel
- GPU thermal throttling → extremely slow inference
- GPU driver bug → stuck operation
- Network issue → hung data transfer

## Solution

### 1. Added Timeout Configuration

Configurable timeouts (in seconds) for each operation:

```python
SYNTHESIZE_TIMEOUT_SECONDS = 30       # Max 30s for TTS
TRANSCRIBE_TIMEOUT_SECONDS = 120      # Max 2 min for ASR (longer audio)
TRANSLATE_TIMEOUT_SECONDS = 30        # Max 30s for MT
CONVERT_TIMEOUT_SECONDS = 30          # Max 30s for voice conversion
```

All configurable via environment variables.

### 2. Added Timeout Wrapping to All Inference Calls

Using `asyncio.wait_for()` to timeout long-running operations:

```python
# Before (no timeout):
await loop.run_in_executor(None, synthesize_text, text, output_path)

# After (with timeout):
await asyncio.wait_for(
    loop.run_in_executor(None, synthesize_text, text, output_path),
    timeout=SYNTHESIZE_TIMEOUT_SECONDS
)
```

**Endpoints with timeouts:**
- `POST /synthesize` — TTS synthesis (30s)
- `POST /synthesize` — Voice conversion (30s) 
- `POST /transcribe` — ASR transcription (120s)
- `POST /translate` — Machine translation (30s)

### 3. TimeoutError Handling

When a request exceeds its timeout, the server:
1. Raises `asyncio.TimeoutError`
2. Logs the timeout with operation name
3. Returns **HTTP 504 (Gateway Timeout)** to client
4. Cleans up resources (cancels operation, releases semaphore)

**Example response:**
```json
{
  "detail": "Synthesis timeout (max 30s)"
}
```

### 4. Graceful Fallback for VC Timeouts

If voice conversion times out, server doesn't fail the request:
- Returns the original (male) voice
- Logs the timeout as a warning
- Client still gets usable audio

```python
if req.gender == "female":
    try:
        await asyncio.wait_for(
            loop.run_in_executor(None, vc_convert, ...),
            timeout=CONVERT_TIMEOUT_SECONDS
        )
    except asyncio.TimeoutError:
        logger.warning("VC timeout — returning male voice")
        # Client gets male voice instead of female
```

## Behavior

### Successful request (under timeout)
```
POST /synthesize
→ TTS runs for 2s (< 30s timeout)
← 200 OK with audio_url
```

### Timeout request
```
POST /synthesize  
→ TTS runs for 35s (> 30s timeout)
→ TimeoutError raised
→ Operation cancelled
← 504 Gateway Timeout with "Synthesis timeout (max 30s)"
```

### VC timeout (graceful)
```
POST /synthesize?gender=female
→ TTS runs for 2s ✓
→ VC runs for 40s (> 30s timeout) ✗
→ TimeoutError caught
→ Returns male voice instead
← 200 OK with audio_url (male voice)
```

## Configuration

### Default Timeouts

| Operation | Timeout | Reasoning |
|-----------|---------|-----------|
| TTS | 30s | Typical: 2-3s, should never take >30s |
| ASR | 120s | Long audio files can take 30-60s |
| MT | 30s | Typical: 200-500ms, should never take >30s |
| VC | 30s | Typical: 1-2s, should never take >30s |

### In systemd service:
```ini
Environment="SYNTHESIZE_TIMEOUT_SECONDS=30"
Environment="TRANSCRIBE_TIMEOUT_SECONDS=120"
Environment="TRANSLATE_TIMEOUT_SECONDS=30"
Environment="CONVERT_TIMEOUT_SECONDS=30"
```

### Adjustment Examples

**More aggressive (fail fast):**
```ini
Environment="SYNTHESIZE_TIMEOUT_SECONDS=15"  # Tight tolerance
Environment="TRANSCRIBE_TIMEOUT_SECONDS=60"  # ASR max 1 min
```

**More lenient (for slow hardware):**
```ini
Environment="SYNTHESIZE_TIMEOUT_SECONDS=60"  # Allow up to 1 min
Environment="TRANSCRIBE_TIMEOUT_SECONDS=180" # Allow up to 3 min
```

## Startup Logging

On startup, the server logs configured timeouts:

```
✓ TTS loaded successfully
✓ ASR loaded successfully
✓ MT loaded successfully
```

(Timeouts are shown in logs when exceeded)

## Error Codes

| Code | Meaning | Cause |
|------|---------|-------|
| 200 | OK | Request completed within timeout |
| 400 | Bad Request | Invalid input (wrong gender, empty text, etc.) |
| 503 | Service Unavailable | Model not loaded (see /health) |
| 504 | Gateway Timeout | Operation exceeded timeout |
| 500 | Internal Server Error | Model error (OOM, corruption, etc.) |

## Logs

### Normal operation
```
POST /synthesize
TTS synthesis: "test text" → /outputs/abc123.wav
```

### Timeout
```
POST /synthesize
ERROR Synthesis timeout (>30s)
TimeoutError: Task was destroyed but it is pending!
```

### VC timeout (fallback)
```
POST /synthesize?gender=female
TTS synthesis: "test text" → /outputs/abc123.wav
WARNING VC timeout — returning male voice
```

## Testing

### Test timeout behavior

```bash
# This should complete within 30s
time curl -X POST http://143.167.8.81:8000/synthesize \
  -H "Content-Type: application/json" \
  -d '{"text": "hello world"}'

# Check logs for timing
sudo journalctl -u manx-tts -f | grep -i "synthesis\|timeout"
```

### Simulate timeout (not recommended in production)
To test timeout handling without breaking production, edit backend temporarily:

```python
# In synthesize_text() function, add:
import time
time.sleep(35)  # Sleep longer than 30s timeout

# Then run: it will timeout after 30s
```

### Monitor timeout events
```bash
# Find all timeout events
sudo journalctl -u manx-tts | grep -i "timeout"

# Count timeouts
sudo journalctl -u manx-tts | grep -i "timeout" | wc -l
```

## Monitoring

### Alerts to set up

1. **Any timeout error** — indicates potential GPU issue
   ```
   If "timeout" in logs, investigate:
   - GPU temperature
   - GPU memory fragmentation
   - GPU driver errors
   ```

2. **Frequent timeouts** — indicates server is overloaded
   ```
   If >5 timeouts/hour, consider:
   - Load balancing
   - Reducing timeout thresholds (fail fast)
   - Upgrading GPU
   ```

3. **Increasing timeout rate** — indicates degradation
   ```
   If timeout rate increasing over time, investigate:
   - GPU thermal throttling
   - Memory leaks
   - Driver issues
   ```

## Benefits

✅ **Prevents hung requests** — No indefinite blocking
✅ **Explicit failure** — Client knows operation timed out (504) vs crashed (500)
✅ **Resource cleanup** — Cancelled operations release GPU and semaphores
✅ **Configurable** — Adjust timeouts based on hardware and usage
✅ **VC fallback** — Voice conversion timeout doesn't fail the request
✅ **Production-ready** — Prevents cascading failures from hung GPU ops

## Frontend Impact

No frontend changes required. Timeouts are transparent to users.

Optional frontend enhancements:
- Show timeout duration in tooltip ("Synthesis may take up to 30 seconds")
- Implement client-side timeout and show "Operation taking longer than expected"
- Retry with exponential backoff if 504 received

See [FRONTEND_CHANGES_REQUIRED.md](../FRONTEND_CHANGES_REQUIRED.md) for optional changes.
