# TestFlight releases

`.github/workflows/testflight.yml` archives the app on a self-hosted Apple Silicon Mac and uploads it to TestFlight.

## One-time setup

1. **Runner.** On the Mac: GitHub repo → Settings → Actions → Runners → New self-hosted runner → macOS / ARM64. Install it as a service (`./svc.sh install && ./svc.sh start`). It gets the default labels `self-hosted, macOS, ARM64`.
2. **Mac toolchain.** Xcode 27 in `/Applications` (the workflow picks the newest of `Xcode.app` / `Xcode-beta.app`, or set the `DEVELOPER_DIR` variable). Open Xcode once to accept the license. The first run builds the iSH sandbox and needs Homebrew `llvm`, `lld`, `libarchive`, and `ninja`: `brew install llvm lld libarchive ninja` (Meson is downloaded by the script). The result is cached in `~/Library/Caches/harness-mobile-ci`.
3. **App Store Connect API key.** App Store Connect → Users and Access → Integrations → App Store Connect API → Team key with the **App Manager** (or Admin) role. Add these repository secrets:
   - `ASC_KEY_ID`: the key ID
   - `ASC_ISSUER_ID`: the issuer ID
   - `ASC_KEY_P8`: the contents of `AuthKey_<id>.p8` (raw or base64)
4. **Identity (repository variables).**
   - `APPLE_TEAM_ID`: your team ID
   - `BUNDLE_ID`: e.g. `com.example.harnessmobile`. The extensions become `<BUNDLE_ID>.share` / `.liveactivity`, and the app group becomes `group.<BUNDLE_ID>.share`.
5. **App record.** Create the app in App Store Connect (My Apps → +) with the same `BUNDLE_ID`. The API cannot create app records. Xcode registers the bundle IDs, the App Group, and HealthKit automatically during the first signed archive.

## Releasing

- Actions → TestFlight → Run workflow (optionally set the ref or the marketing version), or
- `git tag testflight/0.1.0-1 && git push origin testflight/0.1.0-1`

The build number is `github.run_number + 100`. Processing in App Store Connect takes about 5–30 minutes. After that the build appears in TestFlight for internal testers.
