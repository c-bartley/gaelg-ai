# Setup: User-Level systemd Service (No Sudo Required)

## ✅ Service is Already Running

Your service is currently running via the user-level systemd. Here's how it was set up:

## Source File Location

**All configuration is in your project directory:**
```
/exp/exp1/acp24csb/web_platform/manx-tts-user.service
```

This is the permanent configuration file. Keep it here with your other project files.

## How to Apply Updates

If you need to modify the service configuration:

1. **Edit the source file:**
   ```bash
   nano /exp/exp1/acp24csb/web_platform/manx-tts-user.service
   ```

2. **Update the active service:**
   ```bash
   # Option A: Copy the updated file (one-time)
   cp /exp/exp1/acp24csb/web_platform/manx-tts-user.service ~/.config/systemd/user/manx-tts.service
   
   # Option B: Create a symlink (recommended for future updates)
   ln -s /exp/exp1/acp24csb/web_platform/manx-tts-user.service ~/.config/systemd/user/manx-tts.service
   ```

3. **Reload and restart:**
   ```bash
   systemctl --user daemon-reload
   systemctl --user restart manx-tts
   ```

## Current Setup

**Service file:** `/exp/exp1/acp24csb/web_platform/manx-tts-user.service`
**Symlinked to:** `~/.config/systemd/user/manx-tts.service`
**Status:** Active and running
**Auto-start:** Enabled (survives reboot and logout)

## Managing the Service

All commands remain the same:

```bash
# Check status
systemctl --user status manx-tts

# View logs
journalctl --user -u manx-tts -f

# Restart
systemctl --user restart manx-tts

# Stop temporarily
systemctl --user stop manx-tts

# Start
systemctl --user start manx-tts
```

See `USER_SERVICE_MANAGEMENT.md` for complete management guide.

## File Structure

```
/exp/exp1/acp24csb/
├── web_platform/
│   ├── manx-tts.service           (system service — for production with sudo)
│   ├── manx-tts-user.service      (user service — currently active)
│   ├── SYSTEMD_SETUP.md           (system service setup guide)
│   ├── USER_SERVICE_MANAGEMENT.md (this user service guide)
│   └── ...
└── ...
```

Use `manx-tts-user.service` for development (no sudo needed).
Use `manx-tts.service` for production (requires sudo and admin).

## Nothing in Your Home Directory

All project files remain in:
```
/exp/exp1/acp24csb/web_platform/
```

The symlink in `~/.config/systemd/user/` just points to the source file in your project directory.
