# Design

- `icon/pip-dictee-icon.png` — the app icon (rendered by the macOS app: `PipDictee --render-icon`).
- `ui/*.dc.html` — the design boards (in-context mockup, pill states, identity, panel, settings, setup, Windows).
  They're Design-canvas files: they open in that tool, not directly in a browser.

To see the **real** screens instead: `PipDictee --snapshot <folder> [lang]` on macOS (every screen as PNG), and
`windows/ui/ui.html#gallery&lang=fr` in a browser for Windows (see CONTRIBUTING.md).

The look follows Pip's brand: the coral Pip character, Fredoka / Nunito (SF Rounded and Segoe UI in the apps for
now), night ink, coral and lilac. Each app state is one of Pip's moods: listening, thinking, happy, honest oops,
needs you.
