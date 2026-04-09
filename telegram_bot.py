#!/usr/bin/env python3
"""
Gaelg AI — Telegram command bot (long-polling).
Runs as a persistent user service. Responds to commands within ~1 second.
"""

import json
import logging
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

# ---------------------------------------------------------------------------
# Config (from environment variables)
# ---------------------------------------------------------------------------

TOKEN       = os.environ["TELEGRAM_TOKEN"]
CHAT_ID     = int(os.environ["TELEGRAM_CHAT_ID"])
API         = f"https://api.telegram.org/bot{TOKEN}"

LOG_FILE    = os.environ.get("LOG_DIR", "/exp/exp1/acp24csb/web_platform/logs")
LOG_FILE    = os.path.join(LOG_FILE, "gaelg-ai.log")
OUTPUT_DIR  = os.environ.get("OUTPUT_DIR", "/exp/exp1/acp24csb/web_platform/outputs")
HEALTH_URL  = "http://143.167.8.81:8000/health"
GPU_URL     = "http://143.167.8.81:8000/gpu-status"
SERVICE     = "manx-tts"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("gaelg-bot")

# ---------------------------------------------------------------------------
# Telegram API helpers
# ---------------------------------------------------------------------------

def _api(method: str, params: dict = None, timeout: int = 10) -> dict:
    url = f"{API}/{method}"
    data = urllib.parse.urlencode(params or {}).encode() if params else None
    req = urllib.request.Request(url, data=data)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception as e:
        log.warning(f"Telegram API error ({method}): {e}")
        return {}


def send(text: str, parse_mode: str = "Markdown"):
    """Send a message, splitting if over 4096 chars."""
    chunks = [text[i:i+4000] for i in range(0, len(text), 4000)]
    for chunk in chunks:
        _api("sendMessage", {"chat_id": CHAT_ID, "text": chunk, "parse_mode": parse_mode})


def send_code(text: str):
    send(f"```\n{text}\n```")


def fetch(url: str, timeout: int = 5):
    """Fetch a URL, return parsed JSON or None."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Command handlers
# ---------------------------------------------------------------------------

def cmd_help():
    send(
        "🤖 *Gaelg AI Bot*\n\n"
        "*Monitoring*\n"
        "/status — platform health and model availability\n"
        "/gpu — GPU memory usage (cuda:0 and cuda:1)\n"
        "/disk — disk space on outputs and store\n"
        "/uptime — how long the service has been running\n\n"
        "*Logs*\n"
        "/logs — last 50 lines of server log\n"
        "/errors — last 20 ERROR/WARNING lines\n\n"
        "*Control*\n"
        "/restart — restart the platform service\n"
        "/clearoutputs — delete output files older than 24h\n"
        "/requests — request count from the last hour\n"
        "/traffic — total requests per day (all time)"
    )


def cmd_status():
    data = fetch(HEALTH_URL)
    if not data:
        send("🔴 *Gaelg AI* — platform is *offline* (no response from health endpoint)")
        return

    status = data.get("status", "unknown")
    models = data.get("models", {})

    def icon(v): return "✅" if v else "❌"
    overall = "🟢" if status == "healthy" else "🟡"

    send(
        f"{overall} *Gaelg AI* — {status}\n\n"
        f"{icon(models.get('tts'))} TTS (speech synthesis)\n"
        f"{icon(models.get('asr'))} ASR (speech recognition)\n"
        f"{icon(models.get('mt'))}  MT (machine translation)\n"
        f"{icon(models.get('vc'))}  VC (voice conversion)"
    )


def cmd_gpu():
    data = fetch(GPU_URL)
    if not data:
        send("❌ Could not reach GPU status endpoint")
        return

    warn = data.get("warning_threshold_percent", 85)

    def fmt_gpu(key):
        g = data.get(key)
        if not g:
            return f"*{key}* — unavailable"
        alloc = g.get("allocated_gb", 0)
        total = g.get("total_gb", 0)
        pct   = g.get("percent_used", 0)
        icon  = "⚠️" if pct >= warn else "✅"
        return f"{icon} *{key}*\n   {alloc:.1f}GB / {total:.1f}GB ({pct:.1f}%)"

    send(
        f"🖥️ *GPU Status*\n\n"
        f"{fmt_gpu('cuda:0')} (TTS / MT / VC)\n\n"
        f"{fmt_gpu('cuda:1')} (ASR)\n\n"
        f"⚠️ Warning threshold: {warn}%"
    )


def cmd_disk():
    def df(path):
        try:
            result = subprocess.run(
                ["df", "-BM", "--output=size,used,avail,pcent", path],
                capture_output=True, text=True, timeout=5
            )
            lines = result.stdout.strip().splitlines()
            if len(lines) >= 2:
                parts = lines[1].split()
                return parts[0], parts[1], parts[2], parts[3]
        except Exception:
            pass
        return "?", "?", "?", "?"

    out_size, out_used, out_avail, out_pct = df(OUTPUT_DIR)
    store_size, store_used, store_avail, store_pct = df("/store/store1")

    try:
        out_count = sum(1 for _ in Path(OUTPUT_DIR).rglob("*") if _.is_file())
    except Exception:
        out_count = "?"

    send(
        f"💾 *Disk Space*\n\n"
        f"*Output directory*\n"
        f"   Used: {out_used} / {out_size} ({out_pct} full)\n"
        f"   Free: {out_avail}\n"
        f"   Files: {out_count}\n\n"
        f"*Store* (/store/store1)\n"
        f"   Used: {store_used} / {store_size} ({store_pct} full)\n"
        f"   Free: {store_avail}"
    )


def cmd_uptime():
    try:
        result = subprocess.run(
            ["systemctl", "--user", "show", SERVICE, "--property=ActiveEnterTimestamp"],
            capture_output=True, text=True, timeout=5
        )
        started = result.stdout.strip().split("=", 1)[-1]
    except Exception:
        started = "unknown"

    # Calculate human-readable duration from start time
    duration = ""
    try:
        ts_str = started.replace(" UTC", "")
        started_dt = datetime.strptime(ts_str, "%a %Y-%m-%d %H:%M:%S")
        delta = datetime.utcnow() - started_dt
        days = delta.days
        hours, remainder = divmod(delta.seconds, 3600)
        minutes = remainder // 60
        if days > 0:
            duration = f" (up {days}d {hours}h {minutes}m)"
        else:
            duration = f" (up {hours}h {minutes}m)"
    except Exception:
        pass

    send(
        f"⏱️ *Service Uptime*\n\n"
        f"*{SERVICE}* started: {started}{duration}"
    )



def send_plain(text: str):
    """Send plain text with no parse mode — safe for arbitrary log content."""
    chunks = [text[i:i+4000] for i in range(0, len(text), 4000)]
    for chunk in chunks:
        _api("sendMessage", {"chat_id": CHAT_ID, "text": chunk})


def format_log_line(line: str):
    """Parse a log line into (time, message) tuple, or None to skip."""
    # Skip noisy internal library lines
    noisy = ("torch.", "wavlm.", "transformers.", "speechbrain.", "urllib3.", "httpx.")
    for prefix in noisy:
        if f"] {prefix}" in line:
            return None

    # Extract time: "2026-04-09 13:54:56" -> "13:54:56"
    time_col = ""
    if len(line) > 19 and line[10] == " " and line[13] == ":" and line[16] == ":":
        time_col = line[11:19]
        line = line[20:]

    # Strip level + logger name
    for token in ("[INFO] backend.main: ", "[INFO] converter: ", "[INFO] ", "[WARNING] backend.main: ", "[ERROR] backend.main: "):
        if line.startswith(token):
            line = line[len(token):]
            break

    # Prefix warnings/errors
    if "[WARNING]" in line:
        line = line.replace("[WARNING]", "").strip()
        line = "⚠ " + line
    elif "[ERROR]" in line:
        line = line.replace("[ERROR]", "").strip()
        line = "✖ " + line

    # Trim long lines
    if len(line) > 60:
        line = line[:60] + "…"

    return time_col, line.strip()


def cmd_logs():
    p = Path(LOG_FILE)
    if not p.exists():
        send(f"❌ Log file not found: {LOG_FILE}")
        return
    raw = p.read_text(errors="replace").splitlines()
    rows = []
    for line in raw:
        result = format_log_line(line)
        if result:
            rows.append(result)

    rows = rows[-50:]
    table = "\n".join(f"{t}  {m}" for t, m in rows)
    send_plain(table)


def cmd_errors():
    p = Path(LOG_FILE)
    if not p.exists():
        send(f"❌ Log file not found: {LOG_FILE}")
        return
    rows = []
    for l in p.read_text(errors="replace").splitlines():
        if "[ERROR]" in l or "[WARNING]" in l:
            result = format_log_line(l)
            if result:
                rows.append(result)
    if not rows:
        send("✅ No recent errors or warnings in log")
    else:
        send_plain("\n".join(f"{t}  {m}" for t, m in rows[-20:]))


def cmd_restart():
    send("🔄 Restarting *Gaelg AI*...")
    try:
        subprocess.run(["systemctl", "--user", "restart", SERVICE], timeout=15)
        time.sleep(3)
        result = subprocess.run(
            ["systemctl", "--user", "is-active", SERVICE],
            capture_output=True, text=True, timeout=5
        )
        active = result.stdout.strip()
        if active == "active":
            send("✅ Service restarted successfully")
        else:
            send(f"❌ Service failed to restart — status: `{active}`")
    except Exception as e:
        send(f"❌ Restart failed: `{e}`")


def cmd_clearoutputs():
    cutoff = time.time() - 24 * 3600
    deleted = 0
    try:
        for f in Path(OUTPUT_DIR).rglob("*"):
            if f.is_file() and f.stat().st_mtime < cutoff:
                f.unlink()
                deleted += 1
        remaining = sum(1 for f in Path(OUTPUT_DIR).rglob("*") if f.is_file())
        send(f"🗑️ Cleared output files older than 24h — removed *{deleted}* file(s) ({remaining} remaining)")
    except Exception as e:
        send(f"❌ Clear failed: `{e}`")


def cmd_requests():
    p = Path(LOG_FILE)
    if not p.exists():
        send("❌ Log file not found")
        return

    cutoff = (datetime.now() - timedelta(hours=1)).strftime("%Y-%m-%d %H:%M")
    synth = asr = mt = 0
    for line in p.read_text(errors="replace").splitlines():
        ts = line[:16]  # "YYYY-MM-DD HH:MM"
        if ts < cutoff:
            continue
        if "Synthesised:" in line:
            synth += 1
        elif "Transcribed:" in line:
            asr += 1
        elif "Translated (" in line:
            mt += 1

    send(
        f"📊 *Requests (last hour)*\n\n"
        f"🔊 TTS synthesis: {synth}\n"
        f"🎙️ ASR transcription: {asr}\n"
        f"🌐 MT translation: {mt}\n\n"
        f"*Total:* {synth + asr + mt}"
    )


TRAFFIC_FILE = os.path.join(
    os.environ.get("LOG_DIR", "/exp/exp1/acp24csb/web_platform/logs"),
    "traffic.log"
)

def cmd_traffic():
    p = Path(TRAFFIC_FILE)
    if not p.exists():
        send("📊 No traffic data yet — make some requests first.")
        return

    lines = [l for l in p.read_text(errors="replace").splitlines() if l.strip()]
    if not lines:
        send("📊 No traffic data yet.")
        return

    # Bot output: one line per day — date + total only (clean summary)
    # Full detail is in the traffic.log file itself
    rows = []
    for line in lines:
        # "2026-04-09 | TTS: 5 | ASR: 2 | MT: 3 | Total: 10"
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 5:
            continue
        date = parts[0]
        total = parts[4].replace("Total:", "").strip()
        tts   = parts[1].replace("TTS:", "").strip()
        asr   = parts[2].replace("ASR:", "").strip()
        mt    = parts[3].replace("MT:", "").strip()
        rows.append(f"{date}  {total:>4} req  (TTS:{tts}  ASR:{asr}  MT:{mt})")

    send_plain("📊 Traffic log\n\n" + "\n".join(rows))


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

COMMANDS = {
    "/help":         cmd_help,
    "/status":       cmd_status,
    "/gpu":          cmd_gpu,
    "/disk":         cmd_disk,
    "/uptime":       cmd_uptime,
    "/logs":         cmd_logs,
    "/errors":       cmd_errors,
    "/restart":      cmd_restart,
    "/clearoutputs": cmd_clearoutputs,
    "/requests":     cmd_requests,
    "/traffic":      cmd_traffic,
}


def handle(message: dict):
    chat_id = message.get("chat", {}).get("id")
    text    = message.get("text", "").strip()

    if chat_id != CHAT_ID:
        log.warning(f"Ignored message from unauthorised chat_id={chat_id}")
        return

    # Strip bot username suffix (e.g. /start@mybot)
    command = text.split("@")[0].lower() if text else ""
    log.info(f"Command: {command!r}")

    handler = COMMANDS.get(command)
    if handler:
        try:
            handler()
        except Exception as e:
            log.exception(f"Handler failed for {command!r}")
            send(f"❌ Error running `{command}`: {e}")
    elif text:
        send(f"Unknown command: `{text}`\nType /help for available commands.")


# ---------------------------------------------------------------------------
# Long-polling loop
# ---------------------------------------------------------------------------

def main():
    log.info("Gaelg AI bot starting (long-polling)")
    send("🟢 *Gaelg AI Bot* online — send /help for commands")

    offset = 0
    while True:
        try:
            data = _api(
                "getUpdates",
                {"offset": offset, "limit": 10, "timeout": 30},
                timeout=35,
            )
            updates = data.get("result", [])
            for update in updates:
                offset = update["update_id"] + 1
                message = update.get("message") or update.get("edited_message")
                if message:
                    handle(message)
        except KeyboardInterrupt:
            log.info("Bot stopped")
            send("🔴 *Gaelg AI Bot* offline")
            break
        except Exception as e:
            log.warning(f"Polling error: {e} — retrying in 5s")
            time.sleep(5)


if __name__ == "__main__":
    main()
