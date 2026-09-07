"""Independent reference terminal: replay the byte stream psmux's CLIENT wrote
to its outer terminal and dump the resulting visible screen.

Wide-char semantics follow xterm / DEC: a width-2 glyph occupies a lead cell
plus a continuation cell, and touching EITHER half (write or erase) destroys
BOTH halves.
"""
import sys, unicodedata

CONT = "\x00"  # continuation half of a wide glyph


def width(ch):
    if unicodedata.combining(ch):
        return 0
    # AMBIGUOUS-WIDE variant: a CJK-locale terminal renders East Asian
    # Ambiguous characters (box drawing, bullets, +-, curly quotes) as TWO
    # columns. unicode-width, which psmux uses, calls them ONE.
    if unicodedata.east_asian_width(ch) in ("W", "F", "A"):
        return 2
    return 1


class Term:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.g = [[" "] * cols for _ in range(rows)]
        self.saved = None
        self.x = self.y = 0

    def clone_grid(self):
        return [r[:] for r in self.g]

    # -- wide-aware primitives -------------------------------------------
    def _break(self, y, x):
        """Destroy the whole glyph that owns cell (y, x)."""
        if not (0 <= y < self.rows and 0 <= x < self.cols):
            return
        row = self.g[y]
        if row[x] == CONT:
            if x > 0:
                row[x - 1] = " "
            row[x] = " "
        else:
            if x + 1 < self.cols and row[x + 1] == CONT:
                row[x + 1] = " "

    def put(self, ch):
        w = width(ch)
        if w == 0:
            return
        if self.x >= self.cols:
            self.x = 0
            self.y = min(self.y + 1, self.rows - 1)
        if self.x + w > self.cols:
            self.x = 0
            self.y = min(self.y + 1, self.rows - 1)
        self._break(self.y, self.x)
        if w == 2:
            self._break(self.y, self.x + 1)
        self.g[self.y][self.x] = ch
        if w == 2:
            self.g[self.y][self.x + 1] = CONT
        self.x += w

    def erase(self, y, x0, x1):
        """Erase cells [x0, x1) on row y, honouring wide-glyph halves."""
        x0 = max(0, x0)
        x1 = min(self.cols, x1)
        if x0 >= x1:
            return
        self._break(y, x0)
        self._break(y, x1 - 1)
        for x in range(x0, x1):
            self.g[y][x] = " "


def replay(data, cols, rows):
    t = Term(cols, rows)
    alt = None
    i, n = 0, len(data)
    text = data.decode("utf-8", "replace")
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\x1b":
            if i + 1 >= n:
                break
            nxt = text[i + 1]
            if nxt == "[":
                j = i + 2
                priv = ""
                while j < n and text[j] in "?<>=!":
                    priv += text[j]
                    j += 1
                params = ""
                while j < n and (text[j].isdigit() or text[j] in ";: "):
                    params += text[j]
                    j += 1
                if j >= n:
                    break
                fin = text[j]
                ps = [int(p) if p.strip().isdigit() else 0
                      for p in params.replace(" ", "").split(";")] or [0]
                if not params:
                    ps = [0]
                i = j + 1
                if priv == "?" and fin in "hl":
                    for p in ps:
                        if p in (1049, 47, 1047):
                            if fin == "h" and alt is None:
                                alt = (t.clone_grid(), t.x, t.y)
                                t.g = [[" "] * cols for _ in range(rows)]
                            elif fin == "l" and alt is not None:
                                t.g, t.x, t.y = alt[0], alt[1], alt[2]
                                alt = None
                    continue
                if priv:
                    continue
                if fin in "Hf":
                    t.y = max(0, (ps[0] or 1) - 1)
                    t.x = max(0, (ps[1] if len(ps) > 1 else 1) or 1) - 1
                    t.y = min(t.y, rows - 1)
                    t.x = min(t.x, cols - 1)
                elif fin == "A":
                    t.y = max(0, t.y - max(1, ps[0]))
                elif fin == "B":
                    t.y = min(rows - 1, t.y + max(1, ps[0]))
                elif fin == "C":
                    t.x = min(cols - 1, t.x + max(1, ps[0]))
                elif fin == "D":
                    t.x = max(0, t.x - max(1, ps[0]))
                elif fin in "G`":
                    t.x = min(cols - 1, max(0, (ps[0] or 1) - 1))
                elif fin == "d":
                    t.y = min(rows - 1, max(0, (ps[0] or 1) - 1))
                elif fin == "J":
                    m = ps[0]
                    if m == 0:
                        t.erase(t.y, t.x, cols)
                        for y in range(t.y + 1, rows):
                            t.erase(y, 0, cols)
                    elif m == 1:
                        t.erase(t.y, 0, t.x + 1)
                        for y in range(0, t.y):
                            t.erase(y, 0, cols)
                    else:
                        for y in range(rows):
                            t.erase(y, 0, cols)
                elif fin == "K":
                    m = ps[0]
                    if m == 0:
                        t.erase(t.y, t.x, cols)
                    elif m == 1:
                        t.erase(t.y, 0, t.x + 1)
                    else:
                        t.erase(t.y, 0, cols)
                elif fin == "X":
                    cnt = max(1, ps[0])
                    t.erase(t.y, t.x, t.x + cnt)
                elif fin == "P":  # DCH
                    cnt = max(1, ps[0])
                    row = t.g[t.y]
                    t._break(t.y, t.x)
                    del row[t.x:t.x + cnt]
                    row.extend([" "] * cnt)
                elif fin == "@":  # ICH
                    cnt = max(1, ps[0])
                    row = t.g[t.y]
                    t._break(t.y, t.x)
                    for _ in range(cnt):
                        row.insert(t.x, " ")
                    del row[cols:]
                continue
            elif nxt == "]":
                j = i + 2
                while j < n:
                    if text[j] == "\x07":
                        j += 1
                        break
                    if text[j] == "\x1b" and j + 1 < n and text[j + 1] == "\\":
                        j += 2
                        break
                    j += 1
                i = j
                continue
            elif nxt == "7":
                t.saved = (t.x, t.y); i += 2; continue
            elif nxt == "8":
                if t.saved:
                    t.x, t.y = t.saved
                i += 2; continue
            elif nxt in "()#%":
                i += 3; continue
            else:
                i += 2; continue
        if c == "\r":
            t.x = 0
        elif c == "\n":
            t.y = min(rows - 1, t.y + 1)
        elif c == "\b":
            t.x = max(0, t.x - 1)
        elif c == "\t":
            t.x = min(cols - 1, (t.x // 8 + 1) * 8)
        elif c == "\x07":
            pass
        elif ord(c) < 32:
            pass
        else:
            t.put(c)
        i += 1
    return t


def main():
    path = sys.argv[1]
    cols = int(sys.argv[2])
    rows = int(sys.argv[3])
    data = open(path, "rb").read()
    t = replay(data, cols, rows)
    sys.stdout.reconfigure(encoding="utf-8")
    for y in range(rows):
        s = "".join(ch if ch != CONT else "" for ch in t.g[y]).rstrip()
        print("R%02d|%s|" % (y, s))


if __name__ == "__main__":
    main()
