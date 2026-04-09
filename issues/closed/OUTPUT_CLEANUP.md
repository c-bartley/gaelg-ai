# Issue #4: Output Directory Cleanup — RESOLVED

## Problem

Audio synthesis files are written to `/exp/exp1/acp24csb/web_platform/outputs/` and **never deleted**. The directory grows indefinitely and will eventually fill the disk, causing synthesis to fail.

**Current state:**
- 12 MB of WAV files currently stored
- No deletion mechanism
- No monitoring
- Unbounded growth risk

## Solution

### 1. Added Output Cleanup Function

```python
def cleanup_old_outputs():
    """Delete audio files older than OUTPUT_CLEANUP_TTL_HOURS."""
    cutoff_time = time.time() - (OUTPUT_CLEANUP_TTL_HOURS * 3600)
    for filename in os.listdir(OUTPUT_DIR):
        if filename.endswith(".wav"):
            mtime = os.path.getmtime(filepath)
            if mtime < cutoff_time:
                os.unlink(filepath)
                # Log deletion with size info
```

**Features:**
- Only deletes `.wav` files (safe, avoids accidents)
- Deletes files older than `OUTPUT_CLEANUP_TTL_HOURS` (configurable, default 24 hours)
- Logs number of files and total size deleted
- Logs errors if deletion fails (e.g., file in use)

### 2. Added Background Cleanup Task

```python
async def cleanup_loop():
    """Background task: run cleanup every OUTPUT_CLEANUP_INTERVAL_MINUTES."""
    while True:
        await asyncio.sleep(OUTPUT_CLEANUP_INTERVAL_MINUTES * 60)
        cleanup_old_outputs()
```

**Features:**
- Runs every `OUTPUT_CLEANUP_INTERVAL_MINUTES` (configurable, default 60 minutes)
- Runs in background without blocking requests
- Catches and logs all exceptions (cleanup failure doesn't crash server)
- Can be cancelled on shutdown

### 3. Integrated with Startup/Shutdown

```python
@app.on_event("startup")
async def startup():
    # ... model loading ...
    # Start background cleanup task
    _cleanup_task = asyncio.create_task(cleanup_loop())

@app.on_event("shutdown")
async def shutdown():
    # Cancel cleanup task on shutdown
    _cleanup_task.cancel()
```

### 4. Configuration via Environment Variables

Configurable in systemd service or shell:

```bash
# Delete files older than 24 hours
OUTPUT_CLEANUP_TTL_HOURS=24

# Run cleanup every 60 minutes
OUTPUT_CLEANUP_INTERVAL_MINUTES=60
```

Current systemd service settings:
```ini
Environment="OUTPUT_CLEANUP_TTL_HOURS=24"
Environment="OUTPUT_CLEANUP_INTERVAL_MINUTES=60"
```

## Behavior

### Startup
```
✓ Output cleanup scheduled (TTL: 24h, interval: 60m)
```

### Every 60 minutes (or as configured)
```
Output cleanup: deleted 15 files (12.3 MB)
```

### If cleanup fails
```
Output cleanup failed: Permission denied
```

## Configuration Options

| Variable | Default | Description |
|----------|---------|-------------|
| `OUTPUT_CLEANUP_TTL_HOURS` | 24 | Delete files older than this many hours |
| `OUTPUT_CLEANUP_INTERVAL_MINUTES` | 60 | Run cleanup every this many minutes |

### Common Configurations

**Keep files for 1 day (aggressive cleanup):**
```ini
Environment="OUTPUT_CLEANUP_TTL_HOURS=24"
Environment="OUTPUT_CLEANUP_INTERVAL_MINUTES=30"  # Check every 30 min
```

**Keep files for 7 days (conservative cleanup):**
```ini
Environment="OUTPUT_CLEANUP_TTL_HOURS=168"  # 7 * 24
Environment="OUTPUT_CLEANUP_INTERVAL_MINUTES=360"  # Check every 6 hours
```

**Keep files for 3 days, check hourly:**
```ini
Environment="OUTPUT_CLEANUP_TTL_HOURS=72"  # 3 * 24
Environment="OUTPUT_CLEANUP_INTERVAL_MINUTES=60"
```

## Disk Space Protection

With 24-hour TTL and ~70-180 KB per audio file (typical):
- 1,000 synthesis requests/day = 70-180 MB/day
- Cleanup removes all files after 24 hours
- **Max disk usage: ~200 MB** (very safe)

If your usage pattern is different, adjust TTL and interval:

```bash
# Estimate your daily usage:
# requests_per_day * avg_file_size_kb = daily_growth_mb

# Example: 5,000 requests/day, 150KB average
# 5,000 * 150 / 1024 = ~732 MB/day

# So set TTL to 48 hours to keep ~1.5 GB around:
OUTPUT_CLEANUP_TTL_HOURS=48
```

## Manual Cleanup

To manually delete old files without restarting:

```bash
# Delete files older than 24 hours
find /exp/exp1/acp24csb/web_platform/outputs -name "*.wav" -mtime +1 -delete

# Delete files older than 7 days
find /exp/exp1/acp24csb/web_platform/outputs -name "*.wav" -mtime +7 -delete

# See what would be deleted
find /exp/exp1/acp24csb/web_platform/outputs -name "*.wav" -mtime +1
```

## Monitoring

### Check cleanup logs

```bash
# Last 20 cleanup operations
sudo journalctl -u manx-tts -g "Output cleanup" -n 20

# Follow cleanup in real-time
sudo journalctl -u manx-tts -f -g "Output cleanup"
```

### Monitor disk usage

```bash
# Current output directory size
du -sh /exp/exp1/acp24csb/web_platform/outputs

# Track growth over time
watch -n 60 'du -sh /exp/exp1/acp24csb/web_platform/outputs'
```

## Testing

### Test cleanup function directly

```bash
# Create some test files
touch /exp/exp1/acp24csb/web_platform/outputs/test1.wav
touch /exp/exp1/acp24csb/web_platform/outputs/test2.wav

# Backdate them to 25 hours ago
touch -d "25 hours ago" /exp/exp1/acp24csb/web_platform/outputs/test1.wav

# Run cleanup (in Python)
python3 << 'EOF'
import os
import time

OUTPUT_DIR = "/exp/exp1/acp24csb/web_platform/outputs"
OUTPUT_CLEANUP_TTL_HOURS = 24

cutoff_time = time.time() - (OUTPUT_CLEANUP_TTL_HOURS * 3600)
for filename in os.listdir(OUTPUT_DIR):
    filepath = os.path.join(OUTPUT_DIR, filename)
    if filename.endswith(".wav"):
        mtime = os.path.getmtime(filepath)
        age_hours = (time.time() - mtime) / 3600
        if mtime < cutoff_time:
            print(f"WOULD DELETE: {filename} (age: {age_hours:.1f}h)")
        else:
            print(f"KEEP: {filename} (age: {age_hours:.1f}h)")
EOF

# Verify files are kept/deleted correctly
ls -lah /exp/exp1/acp24csb/web_platform/outputs/
```

## Benefits

✅ **Prevents disk filling** — Old files automatically removed
✅ **Configurable TTL** — Adjust retention based on usage
✅ **Background operation** — Cleanup doesn't block requests
✅ **Safe** — Only deletes `.wav` files, logs all operations
✅ **Production-ready** — Integrated with systemd lifecycle

## Frontend Impact

No frontend changes required — cleanup is transparent to users. Audio URLs expire after the configured TTL but clients should not rely on persistent storage anyway.

(If you want to warn users that audio URLs are temporary, see [FRONTEND_CHANGES_REQUIRED.md](../FRONTEND_CHANGES_REQUIRED.md))
