#!/bin/bash
# Health check for Manx TTS platform.
# Polls /health every minute (via cron). Restarts the service if unhealthy.

HEALTH_URL="http://143.167.8.81:8000/health"
LOG_FILE="/exp/exp1/acp24csb/web_platform/logs/healthcheck.log"
MAX_LOG_LINES=10000
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

TELEGRAM_TOKEN="8641754877:AAGberu0hFaq0Fgi4BkkqD6CV_XqM_WmUmo"
TELEGRAM_CHAT_ID="5269120750"

notify() {
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="$1" \
        -d parse_mode="Markdown" > /dev/null 2>&1
}

log() {
    echo "$TIMESTAMP $1" >> "$LOG_FILE"
}

# Trim log if it gets too large
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
    tail -n $((MAX_LOG_LINES / 2)) "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# Query the health endpoint (5 second timeout)
RESPONSE=$(curl -s --max-time 5 "$HEALTH_URL" 2>/dev/null)
EXIT_CODE=$?

# No response — service is down
if [ $EXIT_CODE -ne 0 ] || [ -z "$RESPONSE" ]; then
    log "ERROR: No response from $HEALTH_URL (curl exit $EXIT_CODE) — restarting service"
    notify "⚠️ *Gaelg AI* — no response from health endpoint. Restarting service. ($(date '+%Y-%m-%d %H:%M:%S'))"
    systemctl --user restart manx-tts
    log "INFO: Restart triggered"
    exit 1
fi

# Parse status field from JSON response
STATUS=$(echo "$RESPONSE" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

if [ "$STATUS" = "healthy" ]; then
    # All good — only log occasionally (every ~30 minutes) to avoid noise
    MINUTE=$(date '+%M')
    if [ "$MINUTE" = "00" ] || [ "$MINUTE" = "30" ]; then
        log "OK: Service healthy"
    fi
    exit 0
fi

# Service responded but reports unhealthy (at least one model unavailable)
ERRORS=$(echo "$RESPONSE" | grep -o '"errors":{[^}]*}' || echo "unknown")
log "WARNING: Service unhealthy — $ERRORS — restarting service"
notify "⚠️ *Gaelg AI* — service unhealthy: \`$ERRORS\`. Restarting. ($(date '+%Y-%m-%d %H:%M:%S'))"
systemctl --user restart manx-tts
log "INFO: Restart triggered"
exit 1
