# Critical Privacy Fix: Voice Conversion is Mandatory

## Issue Fixed

**The original Grad-TTS output is never to be returned to users.** It is recognizable as a specific person in the Manx community and identifying.

Previously, there was a fallback that could return the original voice under certain conditions. This has been completely eliminated.

## Current Behavior

### All Synthesis Requests Require Both TTS and VC

```
User Request → TTS Synthesis → Voice Conversion → Return Anonymized Audio
                  (Grad-TTS)      (kNN-VC)          (never original)
```

**Flow for both male and female requests:**
1. Client requests synthesis (with gender: male OR female)
2. Server checks: VC model available? If NO → HTTP 503 (synthesis impossible)
3. Server synthesizes with Grad-TTS → temporary WAV file
4. Server applies voice conversion with requested gender
5. Server returns voice-converted audio
6. Original Grad-TTS audio is deleted or never exposed

### If VC is Unavailable

**All synthesis requests fail with HTTP 503:**
```
POST /synthesize
→ Check VC model loaded?
→ NO → HTTP 503 "Voice conversion model unavailable"
→ Request rejected, no audio returned
```

Never a silent fallback to original voice.

### If VC Times Out

**Request fails with HTTP 504:**
```
POST /synthesize
→ TTS synthesis OK
→ Apply VC conversion...
→ Timeout (>30 seconds) → HTTP 504
→ Request rejected, no audio returned
```

Never returns original voice due to timeout.

### If VC Errors

**Request fails with HTTP 500:**
```
POST /synthesize
→ TTS synthesis OK
→ Apply VC conversion...
→ Error (OOM, model corruption, etc.) → HTTP 500
→ Request rejected, no audio returned
```

Never returns original voice due to error.

## Code Behavior

```python
@app.post("/synthesize")
async def synthesize(req: SynthesizeRequest):
    # CRITICAL: VC must be available for ANY synthesis
    if not model_status["vc"]:
        raise HTTPException(503, "Voice conversion unavailable")
    
    # Synthesize
    async with tts_sem:
        await synthesize_text(text, output_path)  # Creates Grad-TTS audio
    
    # MANDATORY: Always convert, never return original
    async with vc_sem:
        await vc_convert(output_path, output_path, req.gender)
        # output_path now contains voice-converted audio
    
    # Return only the voice-converted version
    return {"audio_url": f"/audio/{filename}"}
```

The original Grad-TTS file is converted in-place. Only the voice-converted version is ever accessible via the `/audio/` endpoint.

## Gender Parameter

The `gender` parameter in `/synthesize` controls which voice conversion target is applied:

```
POST /synthesize
{
  "text": "Bonney vea",
  "gender": "male"        // ← Converts to male anonymized voice
}

POST /synthesize
{
  "text": "Bonney vea",
  "gender": "female"      // ← Converts to female anonymized voice
}
```

**Both are anonymized via voice conversion.** The difference is the target voice profile (male vs female), not original vs converted.

## Privacy Guarantees

✅ **No original voice ever returned** — Even if VC fails, request rejects
✅ **No fallback to original** — Impossible to accidentally leak original voice
✅ **Gender is anonymization target** — Not the source (both come from Grad-TTS)
✅ **Fails safely** — If VC unavailable, synthesis impossible (not degraded)

## Monitoring

If VC is down, all synthesis requests will fail with 503. This is **intentional and correct**.

Watch for this in logs:
```
ERROR Voice conversion model unavailable
```

If this appears, VC model failed to load. Check:
1. `/health` endpoint — `models.vc: false`
2. Model path: `/exp/exp1/acp24csb/model_instances/voice_converter/`
3. GPU memory: May have OOM'd during load

## Frontend Implementation

The frontend MUST check both TTS and VC availability:

```javascript
fetch('/health')
  .then(r => r.json())
  .then(data => {
    // Both required for synthesis
    if (!data.models.tts || !data.models.vc) {
      document.getElementById('synthesizeBtn').disabled = true;
      document.getElementById('synthesizeBtn').title = 
        'Speech synthesis requires TTS and voice conversion models (both unavailable)';
    }
  });
```

**Never allow synthesis if VC is down.** The frontend must respect this constraint.

## What This Prevents

- ❌ Returning recognizable original voice if VC fails
- ❌ Silent degradation to less-safe output
- ❌ User accidentally getting identifiable audio
- ❌ Accidental community member re-identification

## Deployment Notes

When deploying to production:
1. Ensure VC model is always available
2. Monitor VC model health
3. Alert on VC model failures (synthesis will fail)
4. Update frontend to check `/health` and disable synthesis if VC unavailable

This is not a "nice to have" — it's a critical privacy requirement.
