# Changelog

## 1.0.0 - 2026-07-14

- Add a self-contained RedSkill entry point that installs the bundled local marketplace without visiting GitHub.
- Add Windows and macOS RedSkill installers that register the Plugin and launch the pet immediately.
- Add deterministic RedSkill packaging with a SHA-256 checksum.
- Add coordinated Xiaohongshu upload copy, review checklist, and GitHub release notes.

## 0.9.0 - 2026-07-14

- Add a first-run no-pet state that asks Codex for a one-sentence concept or reference image and routes creation into plugin-private storage.
- Enforce a global three-per-hour reminder budget, a ten-minute minimum gap, and a longer bounded Codex opportunity window.
- Record a Codex break opportunity only when its prompt was actually shown.
- Replace the oversized Windows status panel with a compact single-line statistics menu.

## 0.8.1 - 2026-07-14

- Prevent the pet-size slider thumb from being clipped at its minimum value.
- Render every Windows status-menu icon with the matching Fluent icon font and remove missing-glyph boxes.

## 0.8.0 - 2026-07-14

- Track concurrent Codex tasks independently and split health/Codex reminder budgets.
- Credit a full break only after the user returns from the configured idle interval.
- Add semantic action layouts and explicit fallback chains for pets missing tired, sick, rest, celebrate, or held actions.
- Add a Windows settings and diagnostics window with pet picker, size, idle sensitivity, sedentary pace, dialogue tone, quiet hours, and automatic restart.
- Add one-hour/today pause options, local dialogue personalities, responsive small-pet UI, and a 1080x1350 share card.
- Reduce Windows runtime private memory by lazy-loading at most two animation atlases.
- Add visible fatal errors, portable fixtures, lifecycle tests, UI asset tests, and a cross-platform validation definition.

## 0.7.1 - 2026-07-14

- Fix DPI-aware drag and continuous resize on Windows.
- Keep the official Codex pet read-only and isolate all health data in plugin storage.
