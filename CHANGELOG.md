# Changelog

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
