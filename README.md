# Gaelg AI

A web platform for Manx Gaelic (Gaelg) language technology, providing speech synthesis, speech recognition, and machine translation.

**Live site:** [gaelgai.im](https://gaelgai.im)

---

## Features

- **TTS — Text-to-Speech**: Synthesises Manx Gaelic text to speech using Grad-TTS (graphemic) + HiFi-GAN vocoder. All output is passed through voice conversion for speaker anonymisation.
- **ASR — Automatic Speech Recognition**: Transcribes spoken Manx Gaelic using a fine-tuned Whisper large-v3 model.
- **MT — Machine Translation**: Translates between Manx Gaelic and English using NLLB-200 distilled 600M (both directions).
- **VC — Voice Conversion**: kNN-VC (WavLM-Large + HiFi-GAN) applied to all TTS output for privacy protection.

## Architecture

| Component | Model | Device |
|---|---|---|
| TTS | Grad-TTS (graphemic) + HiFi-GAN | cuda:0 |
| ASR | Whisper large-v3 (fine-tuned) | cuda:1 |
| MT | NLLB-200 distilled 600M | cuda:0 |
| VC | kNN-VC (WavLM-Large + HiFi-GAN) | cuda:0 |

The backend is a FastAPI application served via Uvicorn, managed as a user-level systemd service.

## API Endpoints

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/synthesize` | Text-to-speech synthesis |
| `POST` | `/transcribe` | Speech-to-text transcription (single or multiple files) |
| `POST` | `/translate` | Text translation (gv→en or en→gv) |
| `GET` | `/health` | Service and model availability |
| `GET` | `/gpu-status` | GPU memory usage |
| `GET` | `/audio/{filename}` | Retrieve synthesised audio |

## Project Structure

```
web_platform/
├── backend/
│   └── main.py              # FastAPI application
├── frontend/                # Reference copy only — live version deployed on separate server
├── telegram_bot.py          # Telegram monitoring bot (long-polling service)
├── healthcheck.sh           # Cron-based health check and auto-restart
├── manx-tts-user.service    # Systemd user service definition
├── gaelg-bot.service        # Systemd service for Telegram bot
└── .env                     # Credentials (not committed)
```

## Deployment

Requires a `.env` file with:
```
TELEGRAM_TOKEN=...
TELEGRAM_CHAT_ID=...
```

Deploy the user service:
```bash
cp manx-tts-user.service ~/.config/systemd/user/manx-tts.service
cp gaelg-bot.service ~/.config/systemd/user/gaelg-bot.service
systemctl --user daemon-reload
systemctl --user enable --now manx-tts gaelg-bot
loginctl enable-linger 
```

## Notes

- Voice conversion is mandatory for all TTS requests — the original Grad-TTS voice is never returned to protect the privacy of the speaker whose voice the model resembles.
- The `frontend/` directory contains a reference copy of the UI for transparency. The canonical live version is deployed on a separate public-facing server and may differ from this copy.
