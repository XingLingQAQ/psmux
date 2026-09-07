# Issue #639 working notes (DELETE BEFORE FINAL COMMIT)

Reporter: sdaheng, psmux 3.3.8, Win10 21H2.
Symptom: ssh to a box, run psmux there, run `tig`, quit it, and the Chinese
(double width) characters are STILL PAINTED on the screen.

## VERDICT: NOT REPRODUCIBLE on this machine. No fix invented.

Baseline binary: this worktree's `target\release\psmux.exe`, built from a clean
tree at a7332de. (`C:\Users\godwin\.cargo\bin\psmux.exe` was mid-reinstall by
another agent and unusable.) No wide-char commits exist between v3.3.8 and HEAD,
so this build is equivalent to the reporter's version for this code path.

## The three layers checked

    GRID    what psmux's emulator holds          capture-pane -p
    BYTES   what the attached CLIENT paints      conptycap.cs CreatePseudoConsole
    SCREEN  BYTES as a correct terminal sees it  an independent Python reference
                                                 terminal with DEC wide-glyph rules

GRID alone cannot see this bug: `capture-pane` renders a wide glyph from its
lead cell and deliberately SKIPS the trailing half
(`src/copy_mode.rs::push_capture_cell`), so a stranded half is invisible there.
That is why every case below was also checked at the BYTES/SCREEN layer.

## Harness trust gate (kept green throughout)

    L0: [中文测试字符]
       cp: U+4E2D U+6587 U+6D4B U+8BD5 U+5B57 U+7B26

Traps hit and fixed along the way, both of which had FAKED a clean result:
  1. `W "..." + (expr)` in PowerShell passes THREE arguments, so the first fuzz
     runs emitted only cursor moves and compared two blank screens.
  2. The E2E script did not set `[Console]::OutputEncoding`, so capture-pane
     output arrived as "?" and CJK counts were 0. The known-good gate caught it.

## Cases checked, all CLEAN (SCREEN == GRID, row for row)

| # | case | layer | result |
|---|------|-------|--------|
| 1 | CJK only | GRID | clean |
| 2 | CJK then `ab` over the pair | GRID | clean |
| 3 | CJK then `X` over the LEAD half | GRID | clean, orphan became a space |
| 4 | CJK then ED(2) | GRID | clean |
| 5 | alt screen enter/CJK/leave | GRID+SCREEN | clean, `ESC[36X` covers all 36 cols |
| 6 | cufskip: renderer skips a wide span | GRID+SCREEN | clean |
| 7 | tigsim: primary has content, alt has ASCII+CJK | GRID+SCREEN | clean |
| 8 | rightedge, odd pane width 61 | GRID+SCREEN | clean |
| 9 | oddcol, every pair straddles an even boundary | GRID+SCREEN | clean |
| 10 | shrink, short ASCII over a long CJK row, no erase | GRID+SCREEN | clean |
| 11 | scrolling region + CJK then clear | GRID+SCREEN | clean |
| 12 | full repaint on a LATE attach | GRID+SCREEN | clean |
| 13 | split-window narrowing under CJK | GRID+SCREEN | clean |
| 14 | full-width CJK (80 cols) then narrowed to 40, reflow | GRID+SCREEN | clean |
| 15 | randomized property test, 320 incremental mutations, dense final screen | GRID+SCREEN | 8/8 seeds clean |
| 16 | the same through conhost RE-RENDER (ConPTY flags=0, the Win10 path) | GRID+SCREEN | 2/2 seeds clean |
| 17 | Rust erase matrix, 20 ops x 24 offsets | emulator cells | 480/480 clean |

Verbatim post-alt-exit repaint psmux emits (case 5, `cat -v`):

    ^[[?25l^[[HPHASE0-IDLE^[[25X^M
    ^[[36X^M      (x9, one per CJK row)
    ^[[36X^[[36C^[[1;12H^[[?25h

11 + 25 = 36 and 36 = the exact column count of the 18 CJK glyphs. Correct.

## Two controls that make the "clean" results meaningful

* LAX terminal control: replaying the same byte stream through a reference
  terminal that does NOT implement "touching either half destroys both" gives
  the IDENTICAL screen. So psmux does not lean on that terminal rule; it
  repaints both halves explicitly. Robust.
* AMBIGUOUS-WIDE control: replaying through a terminal that renders East Asian
  Ambiguous characters as TWO columns (what a CJK-locale terminal does) DOES
  produce leftovers, e.g. `short 11234568` where the strict terminal shows
  `short 1`. This is the one mechanism that reproduces the reported symptom,
  and it is a WIDTH DISAGREEMENT between psmux and the outer terminal, not a
  psmux erase bug. tmux has the same disposition (utf8_width treats ambiguous
  as 1), so this is not a parity gap either.

## tmux parity finding

tmux `screen-write.c:screen_write_overwrite` does two things: if the cell being
written is PADDING it walks BACKWARD to the owning character and clears it, and
it then walks FORWARD clearing the padding the old character owned.
psmux `crates/vt100-psmux/src/screen.rs::text` does exactly both (clears
`pos.col - 1` when the target is a continuation, and sets the continuation to a
space when the target is wide), and `Cell::set`/`Cell::clear` zero the flag byte
so neither IS_WIDE nor IS_WIDE_CONTINUATION can survive a rewrite. Every erase
path (`erase_all`, `erase_row_forward/backward`, `erase_cells`, `delete_cells`,
`insert_cells`) routes through `Row::erase` -> `Row::clear_wide`, which is the
same rule. tmux resets the orphaned half to `grid_default_cell`, which is a
SPACE, and psmux writes a space too. PARITY HOLDS. The only difference is that
tmux walks a RUN of padding cells (it supports width > 2) while psmux handles
one, which cannot matter for width-2 CJK.

Single `unicode-width 0.2.2` across the whole workspace (checked Cargo.lock), so
psmux and vt100-psmux cannot disagree about a character's width internally.

## Deliverables

* `tests-rs/test_issue639_wide_char_clear.rs` (registered in Cargo.toml), 16
  tests, includes the 480 case erase matrix. 16/16 pass.
* `tests/test_issue639_wide_char_clear.ps1`, 4 checks including an explicit
  known-good CJK round-trip gate. 4/4 pass.

## The one variable I could NOT control

Resizing the OUTER terminal (dragging the ssh client window, i.e. SIGWINCH to
the psmux client) while CJK is on screen. `tests/conptycap.cs` creates a
pseudo console at a fixed size and never calls `ResizePseudoConsole`, so the
client's ratatui buffer never had to be resized under a live wide glyph. A
`Buffer::resize` followed by a diff against the resized previous buffer is a
classic place for stale cells to survive. Everything else on the coordinator's
list was exercised. Covering this properly means teaching conptycap to resize
mid-run; worth doing if the reporter says a resize is involved.

## Diagnostic to ask sdaheng for

1. Which terminal is at the LOCAL end of the ssh session, and its exact version
   (Windows Terminal, PuTTY, conhost, iTerm2, GNOME Terminal, ...).
2. The Windows display language / system locale of the LOCAL machine, and
   whether the terminal is set to a CJK code page (chcp 936 / 950 / 932).
   This is the single hypothesis that survived: a terminal that renders East
   Asian AMBIGUOUS characters as two columns disagrees with psmux, and tig's
   commit graph is made of exactly those characters.
3. Whether the ghost is in the PANE BODY or on the psmux STATUS LINE.
4. `psmux capture-pane -p -e > dump.txt` taken WHILE the ghost is visible. If
   the dump is clean but the screen is dirty, it is the renderer or the outer
   terminal; if the dump is dirty too, it is the emulator.
5. Does it also happen with a plain `clear` after `cat` of a Chinese file, i.e.
   is `tig` required at all?
6. Does it reproduce running psmux LOCALLY on that same box (no ssh)? That
   isolates ssh and the local terminal from psmux.
