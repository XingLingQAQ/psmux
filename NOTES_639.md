# Issue #639 working notes (DELETE BEFORE FINAL COMMIT)

Reporter: sdaheng, psmux 3.3.8, Win10 21H2.
Symptom: ssh to a box, run psmux there, run `tig` (any full screen app), quit it,
and the Chinese (double width) characters are STILL PAINTED on the screen.

Baseline binary for this investigation:
`C:\Users\godwin\Documents\workspace\psmux\.claude\worktrees\agent-a6b74dd9d56cbb991\target\release\psmux.exe`
built from a7332de with a CLEAN tree (so it is a true master baseline).
The shared `C:\Users\godwin\.cargo\bin\psmux.exe` was mid-reinstall by another
agent (renamed aside) and is NOT usable as a baseline right now.

## Harness (all files in ./i639_scratch, mirrored in the session scratchpad)

- `i639_fixture.ps1`   - runs INSIDE a pane, emits a chosen escape-sequence case.
                         Uses `[Console]::Out.Write` (NOT Write-Host) because
                         NO_COLOR=1 in this shell strips Write-Host escapes.
                         Sets `[Console]::OutputEncoding` to UTF8 no-BOM.
- `i639_drive.ps1`     - creates a session running the fixture, then dumps
                         `capture-pane -p` with per-codepoint `U+XXXX` output.
                         This inspects the EMULATOR GRID.
- `i639_fixture2.ps1`  - same but with a 5s idle phase first so an attached
                         client can be hosted before the interesting transition.
- `i639_client_bytes.ps1` - hosts `psmux attach` inside a CreatePseudoConsole
                         (tests/conptycap.cs, flags=8 PASSTHROUGH) and dumps
                         every byte the CLIENT writes to its outer terminal.
                         This inspects the RENDERER OUTPUT (what ssh carries).
- `i639_replay.py`     - INDEPENDENT reference terminal. Replays the captured
                         client byte stream with correct xterm wide-glyph
                         semantics (lead cell + continuation cell; touching
                         EITHER half destroys BOTH) and prints the visible
                         screen. Not psmux code, so it cannot hide a psmux bug.

## Harness trust check (MUST stay green)

`i639_drive.ps1 -Case known_good` prints CJK back through capture-pane:

    L0: [中文测试字符]
       cp: U+4E2D U+6587 U+6D4B U+8BD5 U+5B57 U+7B26

So the harness round trips CJK. Any later CJK loss is psmux, not the shell.

## What "reference replay is clean for the simple case" meant, CONCRETELY

Case `altscreen` in `i639_fixture2.ps1`, pane 60x20:

1. `ESC[H ESC[2J` then `PHASE0-IDLE`, sleep 5s (client attaches here).
2. `ESC[?1049h` (enter alt screen), `ESC[H ESC[2J`.
3. Ten rows of `ESC[<i>;1H` + 18 CJK chars (`中文测试字符` x3) = 36 COLUMNS.
4. sleep 3s, `ESC[?1049l` (leave alt screen), sleep 3s.
5. `ESC[H ESC[2J` then `MARKERAFTER`.

The attached client's outgoing byte stream was captured (1274 bytes). The
post-alt-exit repaint it emitted was, verbatim (`cat -v`):

    ^[[?25l^[[HPHASE0-IDLE^[[25X^M
    ^[[36X^M    (x9, one per CJK row)
    ...
    ^[[36X^[[36C^[[1;12H^[[?25h

i.e. ECH (`ESC[nX`) counts of 25 and 36 COLUMNS, which exactly cover the 36
columns the 18 CJK glyphs occupied. Feeding that same stream through
`i639_replay.py` (the independent reference terminal) produced:

    R00|MARKERAFTER|
    R01..R18 empty
    R19|[i639_base0:pwsh*   "SUPERFLOW" 02:36 08-Sep-26|

NO ghost. So for this shape the renderer erases the wide cells correctly, and
the assertion was "replayed screen has no CJK codepoints left".

## RULED OUT SO FAR (emulator grid, via capture-pane, 1 iteration each)

All of these produced the CORRECT grid, i.e. NOT the bug:

| case             | sequence                                        | result |
|------------------|-------------------------------------------------|--------|
| known_good       | CJK only                                        | `中文测试字符` OK |
| overwrite_short  | CJK row, then `ESC[H` + `ab` (2 cols)           | `ab文测试字符` OK |
| overwrite_odd    | CJK row, then `ESC[H` + `X` (1 col, splits pair)| `X 文测试字符` OK - orphan half correctly became a SPACE |
| erase_2j         | CJK row, then `ESC[2J` + `AFTER`                | `AFTER` OK |
| altscreen (grid) | enter alt, CJK, leave alt, ascii                | clean OK |

## RULED OUT SO FAR (renderer byte stream + independent replay)

| case       | result |
|------------|--------|
| altscreen  | clean, see verbatim bytes above |

## NOT YET TRIED (do these next, one variable at a time, 5+ iterations each)

1. Primary screen that already HAS ASCII CONTENT before entering the alt screen
   (tig returns to a shell with scrollback, my test returned to a near-blank
   screen - the diff is between "CJK alt row" and "ASCII primary row").
2. CUF skip over wide glyphs: row `AAAA中文中文BBBB`, change only `BBBB`.
   If the renderer's skip distance is counted in CHARACTERS not COLUMNS the
   cursor drifts and the old CJK survives. STRONGEST remaining hypothesis.
3. Scrolling region (`ESC[r`) + CJK, then clear. tig uses one.
4. CJK straddling the RIGHT EDGE of the pane (odd pane width, glyph does not fit).
5. Pane RESIZE while CJK is on screen, especially narrowing that splits a pair.
6. Detach / reattach full repaint (reporter is over ssh).
7. Split panes: a wide glyph next to a vertical pane border.

## tmux parity reference (to be read)

`C:\Users\godwin\Documents\workspace\tmux`: `grid.c` GRID_FLAG_PADDING,
`screen-write.c` screen_write_collect_clear / screen_write_cell,
`utf8.c` utf8_width. tmux = one cell of width 2 + a PADDING cell; clearing or
overwriting EITHER half must destroy BOTH.

## Cleanup reminders

Sessions are prefixed `i639_` under `-L i639ns` / `-L i639bn`.
Kill only PIDs whose ExecutablePath is inside this worktree. Never by name.
Remove `$env:USERPROFILE\.psmux\i639_*` leftovers.
