# Windows development handoff

This repository contains the source for **PS2 Classics for Mac 1.0 RC24 (build 33)**. It is a native macOS application. Windows can be used to inspect, edit, and version the source, but this project does not promise a Windows application or a Windows build of the SwiftUI and AppKit targets.

## Clone and review

Clone the private repository from PowerShell:

```powershell
git clone https://github.com/smpduong/ps2-classics-macos.git
cd ps2-classics-macos
```

GitHub will prompt you to authenticate if your saved credentials are not available. Do not commit local game images, memory cards, licensing/support files, keys, generated packages, test outputs, or personal paths and logs.

## Build requirements

The app targets macOS 12 or later. Its Swift package uses Swift 5.9 or later, and `scripts/build-app.sh` creates the Universal arm64/x86_64 macOS app. Building and running that app requires macOS with Xcode/Swift; CMake and Python 3 are also required by the documented development workflow. Windows does not provide the SwiftUI/AppKit SDK needed by these targets. A Windows editor or Git client can help with source work, while a macOS host is needed to build and run the application. No Windows port is included or implied.

On a Mac, the repository documents these commands:

```sh
swift test
bash scripts/build-app.sh
python3 scripts/test-backend.py
python3 scripts/test-extra-formats.py
python3 scripts/test-package-workflow.py
```

## Manually run a macOS development preview

After this workflow is present on the repository's default branch, open **Actions → macOS development preview → Run workflow**. The workflow is manually triggered only. It builds on GitHub's `macos-15` runner, creates a Universal arm64/x86_64 app, runs the Swift tests with the bundled ATRAC3 helper available, and runs the synthetic native-helper regressions. Download the run's artifact to get the preview app archive, a source archive from the exact workflow commit, a manifest with fresh SHA-256 values and build environment details, and a checksum list. The artifact expires after 30 days.

The build retains the release version/build values from `release.json` as embedded app metadata; the artifact is named as a development preview. This workflow does not run the strict release gate, establish PS3/HEN or client-Mac acceptance, or perform Developer ID signing or notarization. The Run workflow button appears after the workflow is committed to the default branch; GitHub requires repository write access to dispatch it.

The strict release gate is `bash scripts/validate-release.sh`. It requires CMake, Python 3, FFmpeg, and MAME `chdman` as test tools. The optional four-image integration run uses `--with-roms` and requires locally supplied images; those images are intentionally absent from this source handoff and must never be added to Git.

## Evidence and open acceptance gates

The current release metadata identifies RC24/build 33. The project records a historical strict RC24 gate with 16 checks and a historical full suite of 224 core plus 37 app tests. Those results describe the recorded macOS run and do not establish a Windows build. No new verification was performed as part of preparing this handoff.

Actual PS3 installation, launch, save/load, multi-disc behavior, Intel Monterey and M4 client runs, external-volume interruption behavior, and Developer ID signing/notarization remain open acceptance gates. The client response is not recorded as received in the project materials. Keep these gates open until evidence from the relevant hardware and release process is recorded.

## Codex delegation preference

When GPT-6 Astra is the top-level model, use Astra as orchestrator, GPT-6.1 Sol as foreman, and GPT-6 Luna for implementation. When GPT-6 Sol or GPT-6.1 Sol is top-level, use Sol as foreman with Luna for implementation.
