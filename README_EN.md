# Notihub

[中文](README.md) | **English**

Notihub turns Mac notifications into a searchable timeline, notes, tasks and daily reviews. The native Mac UI shares its engine with the collector. Mobile clients read the same cloud records by date.

This MIT source snapshot contains `mac/` (SwiftUI UI), `cli/` (collector and local data engine), `ios/` (iPhone/iPad/Watch/Vision sources and XcodeGen specification), and `service/` (self-hostable FastAPI core). It includes no installers, real user content, accounts, device identifiers, certificates, private deployment configuration or Git history.

## Build and verify

Use macOS with a Swift toolchain (Swift 6 for the Mac package) and Python 3.10+. Swift packages use system frameworks only.

```sh
cd cli
swift build -j 4
swift test -j 4
NOTIFHUB_DATA_DIR="$PWD/.test-data" .build/debug/notifhub selftest
cd ../mac
swift build -j 4
swift test -j 4
cd ../ios
swift build -j 4
swift test -j 4
cd ../service
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python smoke.py
.venv/bin/python -m unittest discover -s tests
```

The mobile Swift package verifies production core contracts. Generate the full app with XcodeGen from `ios/project.yml`, then choose your own development team, service URL and destination in Xcode. No signed/notarized package, App Store or TestFlight release is provided. Do not overwrite the author's signed installation. Collection, Apple-data access and reminder writes require authorization by the user on their own machine.

`service/smoke.py` starts a real loopback HTTP server with a temporary database and runtime-generated secrets, checks health and shuts it down. It does not read personal data or relay notifications. The two service test modules can run in separate processes with `unittest discover -s tests -p test_runtime.py` and `-p test_bark.py`.

## Configuration and privacy

Cloud synchronization requires a self-hosted service. `create_app()` reads `NOTIFHUB_ID`, `NOTIFHUB_URL`, `NOTIFHUB_DATABASE`, `NOTIFHUB_SYNC_TOKEN_FILE` and `NOTIFHUB_PROXY_TOKEN_FILE`. Use two different random secrets of at least 32 characters, stored in 0600 files outside the source tree. Bind production HTTP to loopback and deploy your own HTTPS authentication proxy. The proxy must overwrite client-supplied `X-Notifhub-Proxy`. Browser/mobile cookie authentication requires a compatible `/_gate/api/login` service; native `/native/api/` endpoints validate Bearer credentials independently.

Set the mobile `NotihubServiceURL` Info.plist key (the XcodeGen specification has a placeholder) or `NOTIHUB_SERVICE_URL` launch environment to your HTTPS site. Authentication and data requests use the same site. Default `.invalid` addresses cannot reach the author's service. Passwords live in Keychain; automatic password seeding via launch arguments has been disabled.

Mac/CLI use `~/.config/notifhub/` and `~/.local/share/notifhub/`. Set `NOTIFHUB_CONFIG` and `NOTIFHUB_DATA_DIR` to isolate tests. Keep data outside the source tree. Cloud credentials live in an external `cloud-<instanceID>.json` file (`id`, `url`, `token`), with an HTTPS domain matching the current instance's `siteURL`. `examples/` contains unusable placeholder configurations.

Static uploading and remote queue access require `NOTIHUB_UPLOAD_HOST`; an unset host prevents remote access. Optional `NOTIHUB_REMOTE_DIR`, `NOTIHUB_SITE_URL` and `NOTIHUB_QUEUE_URL` configure your own targets. Cloud synchronization uses `notihub sync` separately. Uploading requires explicit `--upload`; generation is local by default.

AI summaries require a separately supplied Python package exposing `tools.llm_client.chat`, configured through `NOTIHUB_LLM_CLIENT_DIR`, or disable `summary.enabled`. The adapter accepts `system`, `message`, `provider`, `timeout` and `origin`, and returns text. The author's model/subscription wrapper is excluded. Summarization sends daily content to the model service you select. `NOTIHUB_REMAIN_SCANNER` optionally points to an external scanner; the author's workspace/handoff scanner is excluded. AI-session collection reads the user's own Claude/Codex logs and can be disabled with `ai.enabled`.

`NOTIHUB_UPDATE_MANIFEST_URL` configures Mac update checking; the default is a placeholder. Mobile builds report that no public release is available. Private update channels are not selected. Optional Bark relay credentials come from external environment configuration and are disabled by default. No SMS or email delivery channel is included.

Demo content and test databases are synthetic. Historical real SMS samples were replaced with fictional text. Screenshots and user exports are excluded. Compilation and isolated tests do not verify real collection permissions, physical devices, reverse-proxy deployment or production synchronization.

## License

Original code and icons are [MIT licensed](LICENSE). See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for dependencies. `snapshot-manifest.json` records source commits and file hashes.
