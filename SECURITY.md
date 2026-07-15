# Security and privacy

## Data boundary

The plugin treats `CODEX_HOME/pets` and `~/.codex/pets` as read-only input. It writes clones, configuration, sanitized hook events, health state, logs, and user-requested share cards only inside Codex plugin data storage.

Hook events contain an event name, timestamp, and a one-way short hash of the Codex session id. Prompt text, model output, repository files, and conversation content are not copied into plugin state. Runtime dialogue generation is local and does not call an LLM.

## Reporting

Open a GitHub security advisory for path traversal, source-pet modification, unsafe deletion, hook-data leakage, or process-control issues. Do not include private pet assets, Codex prompts, or local filesystem paths in a public issue.

## Trust prompt

Codex asks the user to review plugin Hooks. The plugin does not bypass or pre-approve that prompt.
