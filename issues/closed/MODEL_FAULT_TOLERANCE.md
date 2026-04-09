# Issue #3: Model Loading Fault Tolerance — RESOLVED

## Problem

If any model failed to load at startup (corrupted checkpoint, missing file, OOM), the entire server would crash with no graceful degradation or error reporting. Clients had no way to know which features were unavailable.

**Before:**
```
startup() calls:
  load_tts()     ← If this fails, startup aborts. No TTS, ASR, MT, or VC.
  load_asr()     ← If this fails, startup aborts. No ASR, MT, or VC.
  load_mt()      ← If this fails, startup aborts. No MT.
  vc_load_models()  ← If this fails, startup aborts. No VC.
```

## Solution

### 1. Added Model Status Tracking

Global variables track which models loaded successfully:

```python
# Model loading status tracking (for graceful degradation)
model_status = {
    "tts": False,  # Updated during startup
    "asr": False,
    "mt": False,
    "vc": False,
}
model_errors = {}  # {"tts": "error message", ...}
```

### 2. Wrapped Model Loading with Try-Catch

Each model loader is now wrapped in a try-catch block that:
- Catches any exception during loading
- Records the error in `model_errors`
- Sets `model_status[model]` to `False`
- Logs the error
- **Continues to the next model** instead of aborting

**Example:**
```python
# Load TTS
try:
    load_tts()
    model_status["tts"] = True
    logger.info("✓ TTS loaded successfully")
except Exception as e:
    model_status["tts"] = False
    model_errors["tts"] = str(e)
    logger.exception("✗ TTS failed to load")

# Load ASR (continues even if TTS failed)
try:
    load_asr()
    model_status["asr"] = True
    logger.info("✓ ASR loaded successfully")
except Exception as e:
    model_status["asr"] = False
    model_errors["asr"] = str(e)
    logger.exception("✗ ASR failed to load")
# ... and so on
```

### 3. Added `/health` Endpoint

Returns the status of all models so clients can determine which features are available:

**Request:**
```bash
GET /health
```

**Response (all models loaded):**
```json
{
  "status": "healthy",
  "models": {
    "tts": true,
    "asr": true,
    "mt": true,
    "vc": true
  },
  "errors": null
}
```

**Response (some models failed):**
```json
{
  "status": "unhealthy",
  "models": {
    "tts": true,
    "asr": false,
    "mt": true,
    "vc": false
  },
  "errors": {
    "asr": "CUDA out of memory: trying to allocate 2.00 GiB",
    "vc": "FileNotFoundError: /exp/exp1/.../voice_refs/HiFi-TTS/..."
  }
}
```

### 4. Added Model Availability Checks to Endpoints

Each endpoint now checks if its required model is available before processing:

**POST /synthesize:**
```python
@app.post("/synthesize")
async def synthesize(req: SynthesizeRequest):
    # Check if TTS is available
    if not model_status["tts"]:
        raise HTTPException(
            status_code=503,  # Service Unavailable
            detail=f"TTS model unavailable: {model_errors.get('tts', 'unknown error')}"
        )
    # ... proceed with synthesis
```

Returns **HTTP 503 (Service Unavailable)** if the model isn't loaded, with the specific error.

**POST /transcribe:**
```python
if not model_status["asr"]:
    raise HTTPException(
        status_code=503,
        detail=f"ASR model unavailable: {model_errors.get('asr', 'unknown error')}"
    )
```

**POST /translate:**
```python
if not model_status["mt"]:
    raise HTTPException(
        status_code=503,
        detail=f"MT model unavailable: {model_errors.get('mt', 'unknown error')}"
    )
```

### 5. Optional Voice Conversion

Voice conversion (VC) is now optional. If a client requests female voice but VC failed to load:
- Server logs a warning
- Returns the original (male) voice instead of erroring
- Client still gets usable audio

```python
if req.gender == "female":
    if not model_status["vc"]:
        logger.warning("VC unavailable — returning original (male) voice")
    else:
        # Apply voice conversion
```

## Behavior Changes

| Scenario | Before | After |
|----------|--------|-------|
| TTS fails to load | ❌ Server won't start | ✓ Server starts, /synthesize returns 503 |
| ASR fails to load | ❌ Server won't start | ✓ Server starts, /transcribe returns 503 |
| MT fails to load | ❌ Server won't start | ✓ Server starts, /translate returns 503 |
| VC fails to load | ❌ Server won't start | ✓ Server starts, returns male voice instead |
| Client requests female voice, VC unavailable | N/A | ✓ Returns male voice with warning |
| Client wants to check available models | N/A | ✓ GET /health |

## Error Messages

Startup logs now clearly indicate which models loaded and which failed:

```
✓ TTS loaded successfully
✓ ASR loaded successfully
✗ MT failed to load
✓ Voice conversion loaded successfully
✓ Startup complete. Available: tts, asr, vc
⚠️  Unavailable: mt
```

## Testing

### Test model loading failure
To simulate a model loading failure (e.g., for testing), you can temporarily rename a checkpoint:

```bash
# Rename TTS checkpoint to simulate failure
mv /exp/exp1/acp24csb/model_instances/Grad-TTS_graphemic/checkpts/manx-22k.pt \
   /exp/exp1/acp24csb/model_instances/Grad-TTS_graphemic/checkpts/manx-22k.pt.bak

# Start server
cd /exp/exp1/acp24csb/web_platform
python3 -m uvicorn backend.main:app --reload

# Check health
curl http://143.167.8.81:8000/health

# Try to synthesize (should return 503)
curl -X POST http://143.167.8.81:8000/synthesize \
  -H "Content-Type: application/json" \
  -d '{"text": "test"}'

# Restore checkpoint
mv /exp/exp1/acp24csb/model_instances/Grad-TTS_graphemic/checkpts/manx-22k.pt.bak \
   /exp/exp1/acp24csb/model_instances/Grad-TTS_graphemic/checkpts/manx-22k.pt
```

### Test health endpoint

```bash
curl http://143.167.8.81:8000/health | jq .
```

## Benefits

✅ **Partial availability**: If TTS works but ASR doesn't, users can still synthesize speech
✅ **Clear error reporting**: Clients know exactly which models are unavailable and why
✅ **No catastrophic failures**: Server never crashes on model loading
✅ **Graceful degradation**: Female voice falls back to male if VC unavailable
✅ **Production-ready**: Operationally transparent — logs clearly show startup status

## Frontend Impact

**Optional changes for better UX:**
1. **Add /health polling**: Frontend polls `/health` on startup to disable unavailable features
2. **Show disabled features**: Gray out "Transcribe" button if ASR unavailable
3. **Better error messages**: Display specific model error to user if they try unavailable feature

See [FRONTEND_CHANGES_REQUIRED.md](../FRONTEND_CHANGES_REQUIRED.md) for recommended changes.
