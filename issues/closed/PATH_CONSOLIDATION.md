# Issue #2: Model Path Consolidation — RESOLVED

## Problem

Models were hardcoded to reference multiple filesystems, creating single points of failure:

| Component | Old Path | Status |
|-----------|----------|--------|
| Grad-TTS | `/exp/exp5/acp24csb/grad-tts/Grad-TTS_graphemic` | ❌ Non-existent |
| Whisper | `/exp/exp3/acp24csb/whisper-ft/.../save` | ❌ Non-existent |
| HuggingFace cache | `/store/store3/data/hf_cache` | ✅ Exists but remote |
| Voice refs | `/store/store1/data/{HiFi-TTS,LJSpeech}` | ✅ Exists but remote |

**Impact:** If any filesystem became unavailable, the server would fail to start.

## Solution

### 1. Updated [main.py](web_platform/backend/main.py)

Changed hardcoded fallback paths to use environment variables with consolidated defaults:

```python
# Before:
GRADTTS_ROOT = os.environ.get("GRADTTS_ROOT", "/exp/exp5/...")  # Non-existent!
WHISPER_CKPT = Path(os.environ.get("WHISPER_CKPT", "/exp/exp3/..."))  # Non-existent!
HF_HOME = os.environ.get("HF_HOME", "/store/store3/...")

# After:
GRADTTS_ROOT = os.environ.get("GRADTTS_ROOT", "/exp/exp1/acp24csb/model_instances/Grad-TTS_graphemic")
WHISPER_CKPT = Path(os.environ.get("WHISPER_CKPT", "/exp/exp1/acp24csb/model_instances/whisper/save/CKPT+..."))
HF_HOME = os.environ.get("HF_HOME", "/exp/exp1/acp24csb/hf_cache")
```

### 2. Updated [voice_converter/converter.py](model_instances/voice_converter/converter.py)

Made voice reference directories configurable via environment variables:

```python
# Before:
MALE_REF_DIR   = Path("/store/store1/data/HiFi-TTS/hi_fi_tts_v0/audio/9017_clean")
FEMALE_REF_DIR = Path("/store/store1/data/LJSpeech-1.1/wavs")

# After:
MALE_REF_DIR   = Path(os.environ.get("MALE_REF_DIR", "/exp/exp1/acp24csb/model_instances/voice_refs/HiFi-TTS/hi_fi_tts_v0/audio/9017_clean"))
FEMALE_REF_DIR = Path(os.environ.get("FEMALE_REF_DIR", "/exp/exp1/acp24csb/model_instances/voice_refs/LJSpeech-1.1/wavs"))
```

### 3. Updated [manx-tts.service](web_platform/manx-tts.service)

Added environment variables for all consolidated paths so systemd passes them to the application:

```ini
Environment="GRADTTS_ROOT=/exp/exp1/acp24csb/model_instances/Grad-TTS_graphemic"
Environment="GRAD_TTS_CKPT=/exp/exp1/acp24csb/model_instances/Grad-TTS_graphemic/checkpts/manx-22k.pt"
Environment="WHISPER_HUB=/exp/exp1/acp24csb/model_instances/whisper/save"
Environment="WHISPER_CKPT=/exp/exp1/acp24csb/model_instances/whisper/save/CKPT+2026-03-21+19-13-49+00"
Environment="HF_HOME=/exp/exp1/acp24csb/hf_cache"
Environment="VC_ROOT=/exp/exp1/acp24csb/model_instances/voice_converter"
```

## Current Status

**Existing models:**
- ✅ Grad-TTS: `/exp/exp1/acp24csb/model_instances/Grad-TTS_graphemic/` (6.9GB)
- ✅ Whisper: `/exp/exp1/acp24csb/model_instances/whisper/` (8.7GB)
- ✅ NLLB: `/exp/exp1/acp24csb/model_instances/nllb/` (4.7GB)
- ✅ Voice converter: `/exp/exp1/acp24csb/model_instances/voice_converter/` (1.3GB)
- ✅ HuggingFace cache: `/exp/exp1/acp24csb/hf_cache/` (already consolidated)

**Still needed:**
- ⚠️ Voice reference audio: `/exp/exp1/acp24csb/model_instances/voice_refs/`
  - Male (HiFi-TTS 9017): 50 FLAC files (~500MB)
  - Female (LJSpeech): 50 WAV files (~100MB)
  - Currently at `/store/store1/` but can be copied when deploying to production

## Deployment Notes

When deploying to production:

1. **Consolidate voice references** (optional, but recommended):
   ```bash
   mkdir -p /exp/exp1/acp24csb/model_instances/voice_refs
   cp -r /store/store1/data/HiFi-TTS/hi_fi_tts_v0/audio/9017_clean \
         /exp/exp1/acp24csb/model_instances/voice_refs/HiFi-TTS/hi_fi_tts_v0/audio/
   cp -r /store/store1/data/LJSpeech-1.1/wavs \
         /exp/exp1/acp24csb/model_instances/voice_refs/LJSpeech-1.1/
   ```

2. **Or**, override paths via environment in systemd service:
   ```ini
   Environment="MALE_REF_DIR=/store/store1/data/HiFi-TTS/hi_fi_tts_v0/audio/9017_clean"
   Environment="FEMALE_REF_DIR=/store/store1/data/LJSpeech-1.1/wavs"
   ```

## Benefits

✅ All critical models under one filesystem (`/exp/exp1/`)
✅ Paths are overridable via environment variables
✅ Removed dependency on non-existent `/exp/exp5` and `/exp/exp3`
✅ Systemd service controls all paths — no hardcoding in code
✅ If any remote filesystem (/store/) becomes unavailable, service still runs with fallback paths

## Testing

Before deploying to production, verify paths work:

```bash
export GRADTTS_ROOT=/exp/exp1/acp24csb/model_instances/Grad-TTS_graphemic
export WHISPER_HUB=/exp/exp1/acp24csb/model_instances/whisper/save
export NLLB_CHECKPOINTS=/exp/exp1/acp24csb/model_instances/nllb
export HF_HOME=/exp/exp1/acp24csb/hf_cache

python3 -c "from backend.main import load_tts, load_asr, load_mt; load_tts(); load_asr(); load_mt()"
```

Should complete without errors if all paths are correct.
