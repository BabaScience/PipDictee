**What this changes, and why:**

**Tested on:** <!-- macOS 15 / Windows 11 / browser preview of windows/ui/ui.html … -->

- [ ] Clean-up changes are in both apps and in `shared/cleanup-cases.json`
- [ ] New interface strings are in every `shared/i18n/*.json` (`python3 scripts/i18n.py` passes)
- [ ] No network call other than `127.0.0.1`, no dictated text in logs
- [ ] Screenshots for UI changes (`PipDictee --snapshot` on macOS, `ui.html#gallery` for Windows)
