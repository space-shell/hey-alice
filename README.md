# hey-alice

**Alice** — a docked, always-on voice companion that drives [Paseo](https://github.com/space-shell/xagent) agents.
Named for Alice & Bob. Runs on a rooted Bluefox NX1 (Android 15).

- Wake word: "Hey Alice" + side-button hold-to-talk
- Full-duplex audio with on-device VAD and barge-in
- Speech: Paseo speech pipeline / z.ai realtime if viable, else faster-whisper + Kokoro cascade
- Networking: Paseo relay (E2EE) first, Tailscale second — works over 4G

Development plan and milestones: [`docs/plan.md`](docs/plan.md) (double diamond; M0 = device bring-up).

## Layout

```
app/       Android app (service-first): AliceService, audio engine, wake word, VAD,
           voice session state machine, Paseo connection, minimal Compose status UI
gateway/   Server-side voice gateway: streaming STT/TTS behind one WebSocket (M1/M2)
docs/      Plan + protocol docs
```

## Development

Dependencies are managed in `flake.nix` devshells:

```bash
nix develop            # app shell: JDK 17, gradle, adb/fastboot, scrcpy
cd gateway && nix develop   # gateway shell: Python + STT/TTS deps in .venv
```

First build (inside the app devshell):

```bash
gradle wrapper --gradle-version 8.11.1
export ANDROID_HOME=$HOME/Android/Sdk   # SDK with platform 35
./gradlew :app:assembleDebug
```

The Paseo connection layer is adapted from `space-shell/xagent` (see plan ADR-3);
xagent remains a UI-first launcher and is not a build dependency of this repo.
