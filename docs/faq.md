# FAQ

**Q: Is psmux cross-platform?**
A: No. psmux is built exclusively for Windows using the Windows ConPTY API. For Linux/macOS, use tmux. psmux is the Windows counterpart.

**Q: Does psmux work with Windows Terminal?**
A: Yes! psmux works great with Windows Terminal, PowerShell, cmd.exe, ConEmu, and other Windows terminal emulators.

**Q: Why use psmux instead of Windows Terminal tabs?**
A: psmux offers session persistence (detach/reattach), synchronized input to multiple panes, full tmux command scripting, hooks, format engine, and tmux-compatible keybindings. Windows Terminal tabs can't do any of that.

**Q: Can I use my existing `.tmux.conf`?**
A: Yes! psmux reads `~/.tmux.conf` automatically. Most tmux config options, key bindings, and style settings work as-is.

**Q: Can I use tmux themes?**
A: Yes. psmux supports 14 style options with 24-bit true color, 256 indexed colors, and text attributes (bold, italic, dim, etc.). Most tmux theme configs are compatible.

**Q: Can I use tmux commands with psmux?**
A: Yes! psmux includes a `tmux` alias. Commands like `tmux new-session`, `tmux attach`, `tmux ls`, `tmux split-window` all work. 83 commands in total.

**Q: How fast is psmux?**
A: Session creation takes < 100ms. New windows/panes add < 80ms overhead. The bottleneck is your shell's startup time, not psmux. Compiled with opt-level 3 and full LTO.

**Q: Does psmux support mouse?**
A: Full mouse support: click to focus panes, drag to resize borders, scroll wheel, click status-bar tabs, drag-select text, right-click copy. Plus VT mouse forwarding for TUI apps like vim, htop, and midnight commander.

**Q: What shells does psmux support?**
A: PowerShell 7 (default), PowerShell 5, cmd.exe, Git Bash, WSL, nushell, and any Windows executable. Change with `set -g default-shell <shell>`.

**Q: Is it stable for daily use?**
A: Yes. psmux is stress-tested with 15+ rapid windows, 18+ concurrent panes, 5 concurrent sessions, kill+recreate cycles, and sustained load, all with zero hangs or resource leaks.

**Q: PSReadLine predictions / intellisense / autocompletion (inline history suggestions) are disabled inside psmux. How do I enable them?**
A: Add `set -g allow-predictions on` to your `~/.psmux.conf`. This tells psmux to preserve your `PredictionSource` setting after initialization. If your profile sets `PredictionSource` explicitly, psmux respects that. If not, psmux restores the system default (typically `HistoryAndPlugin`). See the [PSReadLine Predictions](configuration.md#psreadline-predictions-intellisense--autocompletion) section in the configuration docs for details.

**Q: How do I use a custom config file?**
A: Use the `-f` flag: `psmux -f /path/to/config.conf`. This loads the specified file instead of the default search order.

**Q: How do I disable warm (pre-spawned) sessions?**
A: Add `set -g warm off` to your config, or set `$env:PSMUX_NO_WARM = "1"`. See [warm-sessions.md](warm-sessions.md) for details.

**Q: Can I set environment variables for panes?**
A: Yes. Use `psmux set-environment -g VARNAME value` to set env vars inherited by all new panes. Use `-gu` to unset. See [configuration.md](configuration.md) for details.

**Q: How do I mute the audible bell inside psmux?**
A: Add `set -g bell-action none` to your `~/.psmux.conf`. This silences both the audible beep and the status bar bell flag. To keep the visual flag but mute the sound, this is not currently split into separate controls. See the [Bell](configuration.md#bell) section in the configuration docs.

**Q: Does psmux work with Claude Code agent teams?**
A: Yes, first-class support. Start psmux, run `claude` inside a pane, and ask Claude to create a team. psmux automatically sets the required environment variables and injects `--teammate-mode tmux`. Each teammate agent gets its own visible pane. See [claude-code.md](claude-code.md) for details.

**Q: Do CJK characters (Chinese/Japanese/Korean) and IME input work?**
A: Yes. CJK character input, IME composition, and pasting CJK text all work correctly. The paste detection heuristic is tuned to avoid misidentifying rapid IME bursts as clipboard pastes, keeping IME input latency minimal.

**Q: Can I save and restore sessions across reboots?**
A: Yes, using the [psmux-resurrect](https://github.com/psmux/psmux-plugins/tree/main/psmux-resurrect) plugin. For automatic periodic save/restore, pair it with [psmux-continuum](https://github.com/psmux/psmux-plugins/tree/main/psmux-continuum). See [plugins.md](plugins.md) for setup.

**Q: Do sessions survive SSH disconnects?**
A: Yes. The psmux session server persists even when your SSH connection drops. After reconnecting, run `psmux attach` to reattach to your sessions.

**Q: Can I prevent psmux from entering copy mode on mouse scroll?**
A: Yes. Add `set -g scroll-enter-copy-mode off` to your config. Scroll events will be passed directly to the running application instead of entering copy mode.

**Q: How do I chain multiple commands in a key binding?**
A: Use `\;` to separate commands: `bind-key M-s split-window -h \; select-pane -L`. The semicolon must be escaped in config files.

**Q: Can I run psmux inside psmux (nested sessions)?**
A: No. psmux prevents nesting to avoid UI confusion. This matches tmux behavior. If you need to connect to a remote psmux, use SSH from within a psmux pane to reach the remote session.

**Q: How do I use Ctrl+Space as my prefix key?**
A: Add to your config: `set -g prefix C-Space` followed by `unbind-key C-b` and `bind-key C-Space send-prefix`.

**Q: Why does `Prefix + I` not work for plugin install?**
A: Make sure you are pressing `Shift+I` (uppercase). Key bindings are case-sensitive: `I` and `i` are distinct bindings.

**Q: How do I reload my config without restarting?**
A: Press `Prefix + :` and type `source-file ~/.psmux.conf`. This works from within a live session. Alternatively, bind it: `bind-key R source-file ~/.psmux.conf \; display-message "Config reloaded"`.

**Q: Does psmux work with Neovim/Vim?**
A: Yes. Ctrl+[, Shift+Tab, mouse events, and truecolor rendering all work correctly inside psmux panes. Set `set -g default-terminal "xterm-256color"` for best compatibility.

**Q: Why does my status bar show a file path instead of the hostname?**
A: PowerShell 7 automatically sets the terminal title to the current working directory on every prompt. If your config has `set -g allow-set-title on` and your status bar format uses `#{pane_title}` or `#T`, you will see that path. By default, `allow-set-title` is `off` in psmux so this does not happen. If you enabled it and want to revert, remove the `allow-set-title on` line from your config, replace `#{pane_title}` with `#H` in your status bar format, or add `$PSStyle.WindowTitle = ''` to your PowerShell profile. See [pane-titles.md](pane-titles.md) for full details.

**Q: Can I run multiple isolated psmux servers?**
A: Yes, use the `-L` flag for server namespaces: `psmux -L work new-session -s dev`. Each namespace gets its own server, sessions, and discovery files.

**Q: How many tmux commands does psmux support?**
A: 83 tmux-compatible commands including session management, window/pane control, copy mode, display popups/menus, interactive choosers, hooks, environment variables, pipe-pane, wait-for synchronization, and more. See [tmux_args_reference.md](tmux_args_reference.md) for the full list.
