# DMUX

🔔 **Warp Terminal toasts when your AI agent finishes.**

Works with **Claude Code**, **Codex CLI**, **OpenCode**, and **Gemini CLI**.

When the agent finishes a turn, asks for input, or goes idle — you get a real OS notification in Warp's top-right corner.

|   |   |
|---|---|
| ✅ | `project — claude done` |
| ⚠️ | `project — codex needs input` |
| 💬 | `project — gemini waiting` |

---

## Install (one command)

```bash
git clone https://github.com/HaD0Yun/DMUX.git ~/.dmux && ~/.dmux/install.sh
```

The installer detects which agents you have installed, asks once, and wires everything for you. Existing hooks in your config files are preserved.

Restart your agent sessions after install. Done.

---

## Uninstall

```bash
~/.dmux/install.sh --uninstall
```

Removes only the DMUX entries; your other hooks stay.

---

## Requirements

- Warp Terminal (any recent build).
- `bash`, `jq` (recommended), `tmux ≥ 3.3` if you run agents inside tmux.

MIT — see [LICENSE](LICENSE).
