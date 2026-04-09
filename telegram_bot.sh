#!/bin/bash
# Gaelg AI — Telegram command bot.
# Run every minute via cron. Polls for new messages and responds to commands.
# Only responds to the authorised chat ID.

# Credentials must be set as environment variables (not hardcoded)
# Set TELEGRAM_TOKEN and TELEGRAM_CHAT_ID in the environment before running
if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo "ERROR: TELEGRAM_TOKEN and TELEGRAM_CHAT_ID must be set" >&2
    exit 1
fi
API="https://api.telegram.org/bot${TELEGRAM_TOKEN}"

OFFSET_FILE="/exp/exp1/acp24csb/web_platform/logs/telegram_bot.offset"
LOG_FILE="/exp/exp1/acp24csb/web_platform/logs/gaelg-ai.log"
OUTPUT_DIR="/exp/exp1/acp24csb/web_platform/outputs"
HEALTH_URL="http://143.167.8.81:8000/health"
GPU_URL="http://143.167.8.81:8000/gpu-status"
SERVICE_NAME="manx-tts"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

send() {
    local text="$1"
    # Telegram max message length is 4096 chars — split if needed
    if [ ${#text} -le 4096 ]; then
        curl -s -X POST "${API}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${text}" \
            -d parse_mode="Markdown" > /dev/null 2>&1
    else
        # Split into chunks at newlines
        echo "$text" | fold -s -w 4000 | while IFS= read -r chunk; do
            curl -s -X POST "${API}/sendMessage" \
                -d chat_id="${TELEGRAM_CHAT_ID}" \
                --data-urlencode "text=${chunk}" \
                -d parse_mode="Markdown" > /dev/null 2>&1
        done
    fi
}

send_code() {
    local text="$1"
    send "\`\`\`
${text}
\`\`\`"
}

# ---------------------------------------------------------------------------
# Command handlers
# ---------------------------------------------------------------------------

cmd_help() {
    send "🤖 *Gaelg AI Bot*

*Monitoring*
/status — platform health and model availability
/gpu — GPU memory usage (cuda:0 and cuda:1)
/disk — disk space on outputs and store
/uptime — how long the service has been running
/health — raw JSON from health endpoint

*Logs*
/logs — last 50 lines of server log
/errors — last 20 ERROR/WARNING lines

*Control*
/restart — restart the platform service
/clearoutputs — delete output files older than 24h
/requests — request count from the last hour"
}

cmd_status() {
    local response
    response=$(curl -s --max-time 5 "$HEALTH_URL" 2>/dev/null)
    local exit_code=$?

    if [ $exit_code -ne 0 ] || [ -z "$response" ]; then
        send "🔴 *Gaelg AI* — platform is *offline* (no response from health endpoint)"
        return
    fi

    local status tts asr mt vc
    status=$(echo "$response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    tts=$(echo "$response" | grep -o '"tts":[a-z]*' | cut -d':' -f2)
    asr=$(echo "$response" | grep -o '"asr":[a-z]*' | cut -d':' -f2)
    mt=$(echo "$response"  | grep -o '"mt":[a-z]*'  | cut -d':' -f2)
    vc=$(echo "$response"  | grep -o '"vc":[a-z]*'  | cut -d':' -f2)

    status_icon() { [ "$1" = "true" ] && echo "✅" || echo "❌"; }

    local overall_icon
    [ "$status" = "healthy" ] && overall_icon="🟢" || overall_icon="🟡"

    send "${overall_icon} *Gaelg AI* — ${status}

$(status_icon "$tts") TTS (speech synthesis)
$(status_icon "$asr") ASR (speech recognition)
$(status_icon "$mt")  MT (machine translation)
$(status_icon "$vc")  VC (voice conversion)"
}

cmd_gpu() {
    local response
    response=$(curl -s --max-time 5 "$GPU_URL" 2>/dev/null)
    local exit_code=$?

    if [ $exit_code -ne 0 ] || [ -z "$response" ]; then
        send "❌ Could not reach GPU status endpoint"
        return
    fi

    # Parse cuda:0
    local alloc0 total0 pct0 alloc1 total1 pct1 warn
    alloc0=$(echo "$response" | grep -o '"allocated_gb":[0-9.]*' | head -1 | cut -d':' -f2)
    total0=$(echo "$response" | grep -o '"total_gb":[0-9.]*'     | head -1 | cut -d':' -f2)
    pct0=$(echo "$response"   | grep -o '"percent":[0-9.]*'      | head -1 | cut -d':' -f2)
    alloc1=$(echo "$response" | grep -o '"allocated_gb":[0-9.]*' | tail -1 | cut -d':' -f2)
    total1=$(echo "$response" | grep -o '"total_gb":[0-9.]*'     | tail -1 | cut -d':' -f2)
    pct1=$(echo "$response"   | grep -o '"percent":[0-9.]*'      | tail -1 | cut -d':' -f2)
    warn=$(echo "$response"   | grep -o '"warning_threshold_percent":[0-9.]*' | cut -d':' -f2)

    gpu_icon() {
        local pct="$1" threshold="$2"
        # compare using awk since bash can't do float comparison
        if awk "BEGIN{exit !($pct >= $threshold)}"; then
            echo "⚠️"
        else
            echo "✅"
        fi
    }

    icon0=$(gpu_icon "$pct0" "$warn")
    icon1=$(gpu_icon "$pct1" "$warn")

    send "🖥️ *GPU Status*

${icon0} *cuda:0* (TTS / MT / VC)
   ${alloc0}GB / ${total0}GB (${pct0}%)

${icon1} *cuda:1* (ASR / Whisper)
   ${alloc1}GB / ${total1}GB (${pct1}%)

⚠️ Warning threshold: ${warn}%"
}

cmd_disk() {
    local out_total out_used out_free out_pct
    out_total=$(df -BM "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2{print $2}')
    out_used=$(df -BM "$OUTPUT_DIR" 2>/dev/null  | awk 'NR==2{print $3}')
    out_free=$(df -BM "$OUTPUT_DIR" 2>/dev/null  | awk 'NR==2{print $4}')
    out_pct=$(df "$OUTPUT_DIR" 2>/dev/null        | awk 'NR==2{print $5}')

    local store_total store_used store_free store_pct
    store_total=$(df -BM /store/store1 2>/dev/null | awk 'NR==2{print $2}')
    store_used=$(df -BM /store/store1 2>/dev/null  | awk 'NR==2{print $3}')
    store_free=$(df -BM /store/store1 2>/dev/null  | awk 'NR==2{print $4}')
    store_pct=$(df /store/store1 2>/dev/null        | awk 'NR==2{print $5}')

    local out_count
    out_count=$(find "$OUTPUT_DIR" -type f 2>/dev/null | wc -l)

    send "💾 *Disk Space*

*Output directory* (${OUTPUT_DIR})
   Used: ${out_used} / ${out_total} (${out_pct} full)
   Free: ${out_free}
   Files: ${out_count}

*Store* (/store/store1)
   Used: ${store_used} / ${store_total} (${store_pct} full)
   Free: ${store_free}"
}

cmd_uptime() {
    local uptime_info
    uptime_info=$(systemctl --user show "$SERVICE_NAME" --property=ActiveEnterTimestamp 2>/dev/null | cut -d'=' -f2)

    local load
    load=$(uptime 2>/dev/null)

    if [ -z "$uptime_info" ]; then
        send "⏱️ *Service Uptime*

Could not determine service start time.

*System load:* \`${load}\`"
    else
        send "⏱️ *Service Uptime*

*${SERVICE_NAME}* started: ${uptime_info}

*System load:* \`${load}\`"
    fi
}

cmd_health_raw() {
    local response
    response=$(curl -s --max-time 5 "$HEALTH_URL" 2>/dev/null)
    if [ -z "$response" ]; then
        send "❌ No response from health endpoint"
    else
        send_code "$response"
    fi
}

cmd_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        send "❌ Log file not found: \`${LOG_FILE}\`"
        return
    fi
    local lines
    lines=$(tail -n 50 "$LOG_FILE" 2>/dev/null)
    send_code "$lines"
}

cmd_errors() {
    if [ ! -f "$LOG_FILE" ]; then
        send "❌ Log file not found: \`${LOG_FILE}\`"
        return
    fi
    local lines
    lines=$(grep -E '\[(ERROR|WARNING)\]' "$LOG_FILE" 2>/dev/null | tail -n 20)
    if [ -z "$lines" ]; then
        send "✅ No recent errors or warnings in log"
    else
        send_code "$lines"
    fi
}

cmd_restart() {
    send "🔄 Restarting *Gaelg AI*..."
    systemctl --user restart "$SERVICE_NAME"
    sleep 3
    local active
    active=$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null)
    if [ "$active" = "active" ]; then
        send "✅ Service restarted successfully"
    else
        send "❌ Service failed to restart — status: \`${active}\`"
    fi
}

cmd_clearoutputs() {
    local before after deleted
    before=$(find "$OUTPUT_DIR" -type f 2>/dev/null | wc -l)
    find "$OUTPUT_DIR" -type f -mmin +$((24 * 60)) -delete 2>/dev/null
    after=$(find "$OUTPUT_DIR" -type f 2>/dev/null | wc -l)
    deleted=$((before - after))
    send "🗑️ Cleared output files older than 24h — removed *${deleted}* file(s) (${after} remaining)"
}

cmd_requests() {
    if [ ! -f "$LOG_FILE" ]; then
        send "❌ Log file not found"
        return
    fi
    local since_ts synth_count asr_count mt_count
    since_ts=$(date -d '1 hour ago' '+%Y-%m-%d %H:%M' 2>/dev/null)
    synth_count=$(grep "Synthesised:" "$LOG_FILE" 2>/dev/null | awk -v since="$since_ts" '$0 >= since' | wc -l)
    asr_count=$(grep "Transcribed:" "$LOG_FILE" 2>/dev/null   | awk -v since="$since_ts" '$0 >= since' | wc -l)
    mt_count=$(grep "Translated:" "$LOG_FILE" 2>/dev/null     | awk -v since="$since_ts" '$0 >= since' | wc -l)
    local total=$((synth_count + asr_count + mt_count))

    send "📊 *Requests (last hour)*

🔊 TTS synthesis: ${synth_count}
🎙️ ASR transcription: ${asr_count}
🌐 MT translation: ${mt_count}

*Total:* ${total}"
}

# ---------------------------------------------------------------------------
# Poll for updates and dispatch commands
# ---------------------------------------------------------------------------

# Load last offset
offset=0
if [ -f "$OFFSET_FILE" ]; then
    offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
fi

# Fetch updates
updates=$(curl -s --max-time 10 "${API}/getUpdates?offset=${offset}&limit=10&timeout=0" 2>/dev/null)

if [ -z "$updates" ] || [ "$(echo "$updates" | grep -o '"ok":true')" = "" ]; then
    exit 0
fi

# Check if there are any results
result_count=$(echo "$updates" | grep -o '"update_id"' | wc -l)
if [ "$result_count" -eq 0 ]; then
    exit 0
fi

# Process each update
echo "$updates" | grep -o '"update_id":[0-9]*,"message":{[^}]*}' | while IFS= read -r update; do
    update_id=$(echo "$update" | grep -o '"update_id":[0-9]*' | cut -d':' -f2)
    chat_id=$(echo "$update" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
    text=$(echo "$update" | grep -o '"text":"[^"]*"' | head -1 | cut -d'"' -f4)

    # Update offset (next expected update_id)
    next=$((update_id + 1))
    echo "$next" > "$OFFSET_FILE"

    # Security: only respond to authorised chat
    if [ "$chat_id" != "$TELEGRAM_CHAT_ID" ]; then
        continue
    fi

    # Dispatch command
    case "$text" in
        /help)          cmd_help ;;
        /status)        cmd_status ;;
        /gpu)           cmd_gpu ;;
        /disk)          cmd_disk ;;
        /uptime)        cmd_uptime ;;
        /health)        cmd_health_raw ;;
        /logs)          cmd_logs ;;
        /errors)        cmd_errors ;;
        /restart)       cmd_restart ;;
        /clearoutputs)  cmd_clearoutputs ;;
        /requests)      cmd_requests ;;
        *)
            if [ -n "$text" ]; then
                send "Unknown command: \`${text}\`
Type /help for available commands."
            fi
            ;;
    esac
done
