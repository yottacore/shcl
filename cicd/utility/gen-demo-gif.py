#!/usr/bin/env python3

##	Purpose: Render an animated demo GIF of a CLI program, without recording a
##		real terminal (no ttyd, no asciinema, no ffmpeg - just Pillow). A TOML
##		scenario file scripts the session; each command is "typed" into a fake
##		terminal window with natural timing (slower digits, a beat before flags,
##		the occasional corrected typo), then actually executed so the captured
##		output can never go stale. Motion runs at exactly 50 fps: the cursor
##		glides between cells at sub-pixel resolution rather than teleporting,
##		blinks while the prompt sits idle, and a view that has to scroll moves
##		a constant number of pixels per frame. Output that fits on
##		one screen shows at once, the way a real terminal dumps it; only an
##		overflowing view scrolls. The screen clears between steps, so each
##		command starts at the top of an empty terminal.
##		The loop boundary cuts to a black hold, then straight back to the first
##		frame - a crossfade would cost dozens of full frames for a second of
##		nothing. Frames share one exact master palette, so nothing is ever
##		re-dithered. gifsicle inter-frame optimizes the result when it is
##		installed. Project-agnostic - point it at any scenario.
##	Syntax:
##		gen-demo-gif.py --scenario FILE --out FILE [--bin PATH] [--seed N]
##		  --scenario FILE  TOML scenario (see fLoadScenario for the format)
##		  --out FILE       GIF to write (required)
##		  --bin PATH       program under demo; substituted for {bin} in run=
##		  --seed N         RNG seed; fixed default so reruns are byte-stable
##		  --font NAME      override the scenario's font preference list
##		  --quiet          only errors
##	Exit: 0 wrote the GIF, 2 non-fatal skip (no Pillow, bad scenario, cmd failed).
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


from __future__ import annotations

import argparse
import math
import random
import re
import shlex
import subprocess
import sys
import unicodedata
from pathlib import Path
from typing import Any, NoReturn

try:
	import tomllib
except ImportError:
	sys.stderr.write("gen-demo-gif: needs python 3.11+ (tomllib)\n")
	sys.exit(2)
try:
	from PIL import Image, ImageDraw, ImageFont
except ImportError:
	sys.stderr.write("gen-demo-gif: Pillow not installed\n")
	sys.exit(2)


##	Canvas and window chrome. 960x540 total; the "window" fills the frame, left
##	with just a thin black border.
CANVAS_W, CANVAS_H = 960, 540
MARGIN     = 4        # thin black border around the full-bleed window
TITLE_H    = 34       # title bar height
PAD        = 12       # text inset inside the terminal area

THEME: dict[str, Any] = {
	"outer":    (0, 0, 0),         # black border framing the window
	"border":   (58, 58, 62),      # 1px window outline
	"titlebar": (44, 44, 48),
	"titletxt": (150, 150, 152),
	"dots":     [(158, 96, 92), (158, 142, 92), (105, 148, 100)],   # muted traffic lights
	"bg":       (30, 32, 30),      # terminal background: dark gray, hint of warmth
	"fg":       (166, 227, 161),   # bright pale green
	"gray":     (148, 148, 148),   # prompt punctuation ("standard gray")
	"dim":      (106, 112, 106),   # comments, truncation ellipsis
}
##	user@host tints: dimmer than fg, complementary hues (green sits across from
##	these on the wheel). Two distinct picks per run, seeded.
IDENT_TINTS = [
	(196, 148, 108),   # tan
	(160, 136, 200),   # violet
	(112, 178, 196),   # cyan
	(198, 140, 156),   # rose
	(170, 166, 108),   # olive
]
IDENT_USERS = ["mika", "joss", "arlo", "remy", "kai", "nova", "wren", "finn"]
IDENT_HOSTS = ["basalt", "kestrel", "onyx", "lyra", "quartz", "mesa", "flint", "juno"]

##	Typing model. WPM -> ms/char at the usual 5 chars/word.
##	The numbers below are tuned by watching the result, not derived, and they sit
##	under a plain typing-speed band on purpose: what reads as natural on screen is
##	slower than what a person actually types, because the viewer is reading the
##	command rather than recalling it. Digits are slower again, since a reader
##	takes them in one at a time. Raise them and the demo reads as a replay of a
##	script instead of someone at a terminal.
WPM_LETTERS   = (135, 183)   # per-command draw, then per-char jitter
WPM_DIGITS    = 63           # default; scenario wpm_digits overrides
WPM_NOTES     = (233, 263)   # "# comment" lines fly by
FLAG_PAUSE_MS = (200, 380)   # a beat of thought before a -flag token
TYPO_RATE     = 0.018        # per letter; capped at 2 fixes per command
BLACK_HOLD_MS = 3000         # dark beat at the loop seam; a cut, not a fade
BLINK_MS      = 530          # cursor on/off half-period while idle at the prompt;
                             # one frame per phase, and only the block changes
FRAME_MS      = 20           # 50 fps while scrolling / cursor-gliding; 2cs is the
                             # shortest delay browsers honor, so this is the ceiling
SCROLL_RATE   = 150          # px/s smooth scroll; per-step scrollrate overrides.
                             # Smoothness is rate/50 px per frame - a few px reads
                             # as continuous, and settle() rounds it to an exact
                             # divisor of the line height so velocity never varies
CLEAR_HOLD_MS = 800          # extra read time before the screen wipes for the next step

QWERTY_ROWS = ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]

ANSI_RE = re.compile(r"\x1b(\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|.)")


def fEmojiInit() -> dict[str, Any] | None:
	##	Color emoji are beyond FreeType-via-Pillow now (Noto ships COLRv1), so
	##	glyph tiles come from Pango+cairo instead. Everything here is optional:
	##	if any piece is missing the chars just draw through the monochrome
	##	fallback like before.
	try:
		import cairo
		import gi
		gi.require_version("Pango", "1.0")
		gi.require_version("PangoCairo", "1.0")
		from gi.repository import Pango, PangoCairo
		from fontTools.ttLib import TTFont, TTLibError
	except (ImportError, ValueError):
		return None
	##	fc-match missing or slow, a font file that fails to open or parse, or a
	##	face with no usable cmap (getBestCmap hands back None): each means no
	##	emoji face, not a broken run.
	try:
		out = subprocess.run(["fc-match", "-f", "%{file}\t%{family}", "emoji"],
		                     capture_output=True, text=True, timeout=10).stdout
		path, family = (out.split("\t") + [""])[:2]
		if "emoji" not in family.lower():
			return None
		cmap = set(TTFont(path, lazy=True).getBestCmap())
	except (OSError, subprocess.TimeoutExpired, TTLibError, TypeError):
		return None
	return {"Pango": Pango, "PangoCairo": PangoCairo, "cairo": cairo,
	        "family": family, "cmap": cmap}


EMOJI = fEmojiInit()


def fSkip(msg: str) -> NoReturn:
	##	2 = non-fatal skip, same convention as the other cicd utilities: the
	##	stage warns and the pipeline continues.
	sys.stderr.write(f"gen-demo-gif: {msg}\n")
	sys.exit(2)


def fGifsicle(path: Path) -> int:
	##	Pillow writes every frame whole; at 50 fps that is mostly redundant, so
	##	hand the file to gifsicle for inter-frame diffing + transparency. Exact
	##	(no lossy, no palette change), and silently skipped when not installed.
	##	Returns the new size, or 0 if nothing was done.
	tmp = path.with_name(path.name + ".opt")
	try:
		rc = subprocess.run(["gifsicle", "-O3", "-w", "--loopcount=forever",
		                     "-o", str(tmp), str(path)], timeout=900).returncode
	except (OSError, subprocess.TimeoutExpired):
		rc = 1
	if rc == 0 and tmp.exists() and tmp.stat().st_size:
		tmp.replace(path)
		return path.stat().st_size
	if tmp.exists():
		tmp.unlink()
	return 0


def fFindFont(prefs: list[str], size: int) -> tuple[ImageFont.FreeTypeFont, str]:
	##	Resolve the first available preference via fc-match. fc-match always
	##	answers with its best match, so verify the family before trusting it;
	##	the final fallback takes whatever monospace fontconfig offers.
	for name in prefs + ["monospace"]:
		try:
			out = subprocess.run(
				["fc-match", "-f", "%{file}\t%{family}\t%{style}", name],
				capture_output=True, text=True, timeout=10).stdout
		except OSError:
			break
		path, family, style = (out.split("\t") + ["", ""])[:3]
		want = re.sub(r"[^a-z]", "", name.lower())
		got  = re.sub(r"[^a-z]", "", (family + style).lower())
		if name == "monospace" or (path and want in got):
			try:
				return ImageFont.truetype(path, size), f"{family} {style}".strip()
			except OSError:
				continue
	fSkip("no usable monospace font found")


def fLoadScenario(path: str) -> dict[str, Any]:
	##	Scenario format (TOML):
	##	  title = "window title"        prog = "name shown in typed commands"
	##	  font = ["pref1", "pref2"]     seed = 11
	##	  wpm_digits = 42               digit typing speed (numbers-heavy demos: raise it)
	##	  clear = false                 keep the scrollback between steps (default: clear)
##	  blankafter = false            no blank line between a command's output and the
##	                                next prompt (default: one, for breathing room)
	##	  [[step]]
	##	  note = "shown as a typed # comment first"     (optional; a list = several lines)
	##	  show = "{prog} 255 16"        the command line as typed
	##	  run  = "echo hi | {bin} ..."  what actually executes (default: show)
	##	  expect_exit = 0               step's expected exit; a mismatch aborts the render
	##	  pause = 2.6                   read time after the output, seconds
	##	  overflow = "truncate"         or "wrap" for real feature output
	##	  scrollrate = 260              px/s smooth scroll, when the output overflows
	##	  linems = 26                   ms per output line; 0 (default) dumps the
	##	                                whole screenful at once, like a real terminal
	try:
		with open(path, "rb") as f:
			sc = tomllib.load(f)
	except (OSError, tomllib.TOMLDecodeError) as e:
		fSkip(f"scenario: {e}")
	if not sc.get("step"):
		fSkip("scenario has no [[step]] entries")
	return sc


def fRunStep(step: dict[str, Any], prog: str, binpath: str) -> list[str]:
	##	Execute the step's command for real; stderr goes down the same pipe as
	##	stdout, so notes the program prints on stderr show up where a terminal
	##	would show them. Capturing the two separately and concatenating put every
	##	stderr line after every stdout line, which is an order no terminal
	##	produces - the stdin note `set` prints came out under its own output.
	cmd = step.get("run", step["show"])
	cmd = cmd.replace("{bin}", shlex.quote(binpath)).replace("{prog}", shlex.quote(binpath))
	try:
		res = subprocess.run(["bash", "-c", cmd], stdout=subprocess.PIPE,
		                     stderr=subprocess.STDOUT, text=True,
		                     timeout=30, errors="replace")
	except subprocess.TimeoutExpired:
		fSkip(f"command timed out: {cmd}")
	##	A step that exits off-script (e.g. a renamed flag) prints an error the demo
	##	would otherwise render and publish as if it were real output. Refuse the
	##	render instead; expect_exit lets a step opt into a deliberate nonzero.
	expect = step.get("expect_exit", 0)
	if res.returncode != expect:
		fSkip(f"step exited {res.returncode}, expected {expect}: {cmd}")
	out = ANSI_RE.sub("", res.stdout)
	return [ln.expandtabs(8).rstrip() for ln in out.rstrip("\n").split("\n")]


Event = tuple[tuple[str, str | None], float]   # ((action, char), delay_ms)


def fTypeEvents(text: str, rng: random.Random, wpm_range: tuple[int, int],
                typos: bool = True, wpmDigits: int = WPM_DIGITS) -> list[Event]:
	##	Turn a command string into ((action, char), delay_ms) keystroke events.
	##	Letters ride the per-command WPM draw with per-char jitter, digits get
	##	their own WPM (slow by default, fast for numbers-heavy demos), a -flag
	##	token gets a small hesitation, and a couple of seeded typos get noticed
	##	and backspaced away.
	wpm = rng.uniform(*wpm_range)
	events: list[Event] = []
	fixes = 0
	firstSpace = text.find(" ")
	for i, ch in enumerate(text):
		if ch.isdigit():
			delay = 60000.0 / (wpmDigits * 5) * rng.uniform(0.82, 1.22)
		else:
			delay = 60000.0 / (wpm * 5) * rng.uniform(0.70, 1.34)
			if i < firstSpace:
				delay *= 0.78        # the leading token is muscle memory
		if ch == "-" and (i == 0 or text[i - 1] == " "):
			delay += rng.uniform(*FLAG_PAUSE_MS)
		if typos and fixes < 2 and ch.isalpha() and rng.random() < TYPO_RATE:
			wrong = fNeighborKey(ch, rng)
			events.append((("type", wrong), delay))
			overshoot = None
			if i + 1 < len(text) and text[i + 1].isalpha() and rng.random() < 0.4:
				overshoot = text[i + 1]      # one more char before noticing
				events.append((("type", overshoot), 60000.0 / (wpm * 5)))
			events.append((("pause", None), rng.uniform(320, 640)))
			for _ in range(2 if overshoot else 1):
				events.append((("bs", None), rng.uniform(95, 150)))
			events.append((("type", ch), rng.uniform(140, 260)))
			fixes += 1
			continue
		events.append((("type", ch), delay))
	return events


def fNeighborKey(ch: str, rng: random.Random) -> str:
	for row in QWERTY_ROWS:
		pos = row.find(ch.lower())
		if pos < 0:
			continue
		near = [row[j] for j in (pos - 1, pos + 1) if 0 <= j < len(row)]
		pick = rng.choice(near)
		return pick.upper() if ch.isupper() else pick
	return ch


##	Palette: one shared 256-entry table for every frame. The text colors have
##	short blend ramps toward their background so antialiased edges quantize
##	cleanly instead of dithering, and the leftover entries are median-cut from
##	the emoji tiles the scenario actually produces. One global table means no
##	per-frame palette cost; fades darken it per frame (local palettes), leaving
##	pixel indexes untouched.
RGB = tuple[int, int, int]


def fBuildPalette(userTint: RGB, hostTint: RGB, emojiTiles: list[Image.Image]) -> Image.Image:
	def blend(a: RGB, b: RGB, k: float) -> RGB:
		return (round(a[0] + (b[0] - a[0]) * k), round(a[1] + (b[1] - a[1]) * k), round(a[2] + (b[2] - a[2]) * k))
	t = THEME
	colors = [(0, 0, 0), t["outer"], t["border"], t["titlebar"],
	          t["titletxt"], t["bg"], t["fg"], t["gray"], t["dim"],
	          userTint, hostTint] + t["dots"]
	##	The cursor's partial-coverage edge rides this ramp too; four steps put its
	##	sub-pixel position within a fifth of a pixel, and a denser ramp only costs
	##	file size (every antialiased edge in the frame gets more distinct colors).
	for c in (t["fg"], t["gray"], t["dim"], userTint, hostTint):
		for k in (0.22, 0.45, 0.68, 0.86):
			colors.append(blend(t["bg"], c, k))
	for k in (0.35, 0.7):
		colors.append(blend(t["titlebar"], t["titletxt"], k))
	colors = list(dict.fromkeys(colors))
	if emojiTiles:
		w = sum(tile.width for tile in emojiTiles)
		h = max(tile.height for tile in emojiTiles)
		strip = Image.new("RGB", (max(w, 1), max(h, 1)), t["bg"])
		x = 0
		for tile in emojiTiles:
			strip.paste(tile, (x, 0), tile)
			x += tile.width
		room = min(256 - len(colors), 220)
		q = strip.quantize(colors=room, method=Image.Quantize.MEDIANCUT)
		qp = q.getpalette()
		got = [tuple(qp[i:i + 3]) for i in range(0, room * 3, 3)]
		colors = list(dict.fromkeys(colors + got))
	colors = (colors + [(0, 0, 0)] * 256)[:256]
	pal = Image.new("P", (1, 1))
	pal.putpalette([v for c in colors for v in c])
	return pal


class Screen:
	##	The fake terminal: a scrollback of styled lines plus an in-progress
	##	prompt line, viewed through a pixel-scrolled window. render() draws the
	##	full chrome each time and quantizes straight to the master palette.
	def __init__(self, font, fontName, title, prompt, palImg, fontSize):
		self.font, self.title, self.prompt, self.pal = font, title, prompt, palImg
		self.fontSize = fontSize
		self.showPrompt = True   # hidden while a command's output is scrolling in
		self._glyphFont = {}     # ch -> font that can draw it
		self._fbFonts = {}       # font file -> ImageFont
		self._emojiTiles = {}    # ch -> RGBA tile (or None if it would not render)
		self._notdef = self._mask(font, "\U000FFFFD")
		ascent, descent = font.getmetrics()
		self.cw = font.getlength("0")
		self.lh = ascent + descent + 3
		self.winW = CANVAS_W - 2 * MARGIN
		self.winH = CANVAS_H - 2 * MARGIN
		self.termX = MARGIN + PAD
		self.termY = MARGIN + TITLE_H + PAD
		self.cols = int((self.winW - 2 * PAD) // self.cw)
		self.rows = int((self.winH - TITLE_H - 2 * PAD) // self.lh)
		self.textW = self.winW - 2 * PAD
		self.viewH = self.rows * self.lh
		self.lines = []          # committed scrollback: list of [(text, colorkey)]
		self.typed = ""          # text after the prompt on the live line
		self.scroll = 0.0        # view offset into the content, px
		self.fontName = fontName

	def fPut(self, spans):
		self.lines.append(spans)

	def fClear(self):
		##	What `clear` does: scrollback gone, live line back at the top. Keeps
		##	each command in an empty window - focus on it, and far fewer frames.
		self.lines = []
		self.typed = ""
		self.scroll = 0.0

	@staticmethod
	def _mask(font, ch):
		##	getmask returns a raw ImagingCore; box it to get comparable bytes.
		return Image.Image()._new(font.getmask(ch)).tobytes()

	def fFontFor(self, ch):
		##	The primary font, unless it draws ch as .notdef; then whatever
		##	fontconfig says covers that codepoint (e.g. a CJK face for the
		##	Kanji/Hanzi base aliases). Cached hard - fc-match is not cheap.
		if ord(ch) < 0x80:
			return self.font
		hit = self._glyphFont.get(ch)
		if hit:
			return hit
		use = self.font
		if self._mask(self.font, ch) == self._notdef:
			try:
				path = subprocess.run(
					["fc-match", "-f", "%{file}", f":charset={ord(ch):x}"],
					capture_output=True, text=True, timeout=10).stdout.strip()
			except OSError:
				path = ""
			if path:
				if path not in self._fbFonts:
					try:
						self._fbFonts[path] = ImageFont.truetype(path, self.fontSize)
					except OSError:
						self._fbFonts[path] = self.font
				use = self._fbFonts[path]
		self._glyphFont[ch] = use
		return use

	def fIsEmoji(self, ch):
		##	Only chars the emoji face covers, and only from the emoji blocks -
		##	CJK and friends stay on the monochrome fallback fonts.
		return EMOJI is not None and ord(ch) >= 0x2600 and ord(ch) in EMOJI["cmap"]

	def fEmojiTile(self, ch):
		##	Rasterize one emoji via Pango+cairo at 4x, then shrink into the cell
		##	box (two columns wide, like a terminal). Cached; None = unrenderable.
		if ch in self._emojiTiles:
			return self._emojiTiles[ch]
		e = EMOJI
		px = self.lh * 4
		surf = e["cairo"].ImageSurface(e["cairo"].FORMAT_ARGB32, px * 2, px * 2)
		ctx = e["cairo"].Context(surf)
		layout = e["PangoCairo"].create_layout(ctx)
		desc = e["Pango"].FontDescription(e["family"])
		desc.set_absolute_size(px * e["Pango"].SCALE)
		layout.set_font_description(desc)
		layout.set_text(ch, -1)
		e["PangoCairo"].show_layout(ctx, layout)
		surf.flush()
		img = Image.frombuffer("RGBA", (px * 2, px * 2), bytes(surf.get_data()),
		                       "raw", "BGRa", surf.get_stride())
		box = img.getbbox()
		tile = None
		if box:
			glyph = img.crop(box)
			s = min((2 * self.cw - 1) / glyph.width, (self.lh - 2) / glyph.height)
			tile = glyph.resize((max(1, round(glyph.width * s)),
			                     max(1, round(glyph.height * s))), Image.LANCZOS)
		self._emojiTiles[ch] = tile
		return tile

	def fDrawCursor(self, layer, cx, cy):
		##	The block at a fractional position: edge pixels take partial coverage
		##	instead of snapping to the pixel grid, so a 2-3 px/frame glide reads
		##	as continuous motion rather than a series of small jumps. The blends
		##	fall on the same bg->fg ramp the antialiased text already uses, so
		##	they quantize without dithering.
		x0, y0 = cx + 1, cy + 1
		x1, y1 = x0 + self.cw, y0 + self.lh - 3
		ix, iy = math.floor(x0), math.floor(y0)
		w, h = math.ceil(x1) - ix, math.ceil(y1) - iy
		if w < 1 or h < 1:
			return
		xcov = [max(0.0, min(x1, ix + i + 1) - max(x0, ix + i)) for i in range(w)]
		ycov = [max(0.0, min(y1, iy + j + 1) - max(y0, iy + j)) for j in range(h)]
		mask = Image.new("L", (w, h))
		mask.putdata([round(255 * xc * yc) for yc in ycov for xc in xcov])
		layer.paste(THEME["fg"], (ix, iy), mask)

	def fDrawText(self, d, img, x, y, text, fill):
		##	Draw in runs of a single font, so fallback glyphs slot inline. Emoji
		##	go down as color tiles pasted on two terminal cells.
		i = 0
		while i < len(text):
			ch = text[i]
			if self.fIsEmoji(ch):
				tile = self.fEmojiTile(ch)
				if tile:
					img.paste(tile, (round(x + (2 * self.cw - tile.width) / 2),
					                 round(y + (self.lh - 2 - tile.height) / 2) + 1), tile)
					x += 2 * self.cw
					i += 1
					continue
			f = self.fFontFor(ch)
			j = i + 1
			##	Combining marks ride the run of their base char, else shaping
			##	splits and a Devanagari matra draws as dotted-circle + box.
			while j < len(text) and not self.fIsEmoji(text[j]) \
					and (unicodedata.category(text[j]).startswith("M")
					     or self.fFontFor(text[j]) is f):
				j += 1
			d.text((x, y), text[i:j], font=f, fill=fill)
			x += d.textlength(text[i:j], font=f)
			i = j
		return x

	def fCells(self, ch):
		##	Terminal cell count: emoji and East-Asian wide chars take two.
		if self.fIsEmoji(ch) or unicodedata.east_asian_width(ch) in ("W", "F"):
			return 2
		return 1

	def fPutText(self, text, colorkey="fg", overflow="truncate"):
		##	Split on terminal cell widths, not char counts, so wide glyphs
		##	(emoji, CJK) don't push a line past the window edge.
		while True:
			used, cut = 0, len(text)
			for i, ch in enumerate(text):
				used += self.fCells(ch)
				if used > self.cols:
					cut = i
					break
			if overflow == "truncate" and cut < len(text):
				self.fPut([(text[: max(0, cut - 1)], colorkey), ("…", "dim")])
				return
			self.fPut([(text[:cut], colorkey)])
			text = text[cut:]
			if not text:
				break

	def fTextW(self, text):
		##	Pixel width with the same runs fDrawText uses.
		w, i = 0.0, 0
		while i < len(text):
			if self.fIsEmoji(text[i]) and self.fEmojiTile(text[i]):
				w += 2 * self.cw
				i += 1
				continue
			f = self.fFontFor(text[i])
			j = i + 1
			while j < len(text) and not self.fIsEmoji(text[j]) \
					and (unicodedata.category(text[j]).startswith("M")
					     or self.fFontFor(text[j]) is f):
				j += 1
			w += f.getlength(text[i:j])
			i = j
		return w

	def fRestScroll(self):
		##	Where the view settles: content bottom (incl. the live line when the
		##	prompt is showing) on the grid.
		rows = len(self.lines) + (1 if self.showPrompt else 0)
		return max(0.0, rows * self.lh - self.viewH)

	def fCursorTarget(self):
		##	Cursor cell on the live line, in view (layer) px at current scroll.
		x = self.fTextW("".join(t for t, _ in self.prompt) + self.typed)
		return x, len(self.lines) * self.lh - self.scroll

	def render(self, cursor, identColors):
		##	cursor: None = hidden, else (x, y) view px of the block's top-left.
		img = Image.new("RGB", (CANVAS_W, CANVAS_H), THEME["outer"])
		d = ImageDraw.Draw(img)
		x0, y0 = MARGIN, MARGIN
		d.rectangle([x0, y0, x0 + self.winW, y0 + self.winH],
		            fill=THEME["bg"], outline=THEME["border"])
		d.rectangle([x0, y0, x0 + self.winW, y0 + TITLE_H], fill=THEME["titlebar"])
		for i, c in enumerate(THEME["dots"]):
			cx = x0 + 18 + i * 20
			d.ellipse([cx, y0 + 12, cx + 11, y0 + 23], fill=c)
		tw = d.textlength(self.title, font=self.font)
		self.fDrawText(d, img, x0 + (self.winW - tw) / 2,
		               y0 + (TITLE_H - self.lh) / 2 + 1, self.title, THEME["titletxt"])

		##	Text: content lines at their scrolled offsets, drawn on a layer the
		##	size of the view so partial lines clip cleanly at the edges.
		colors = dict(THEME, **identColors)
		layer = Image.new("RGB", (self.textW, self.viewH), THEME["bg"])
		ld = ImageDraw.Draw(layer)
		content = self.lines + ([self.prompt + [(self.typed, "fg")]]
		                        if self.showPrompt else [])
		first = max(0, int(self.scroll // self.lh))
		last = min(len(content), int((self.scroll + self.viewH) // self.lh) + 2)
		for i in range(first, last):
			x, y = 0, round(i * self.lh - self.scroll)
			for text, key in content[i]:
				x = self.fDrawText(ld, layer, x, y, text, colors[key])
		if cursor is not None:
			self.fDrawCursor(layer, *cursor)
		img.paste(layer, (self.termX, self.termY))
		return img.quantize(palette=self.pal, dither=Image.Dither.NONE)


class Movie:
	##	Ordered (frame, duration) list. Identical consecutive frames merge into
	##	one longer frame, so a still hold costs exactly one frame however long it
	##	runs. GIF stores delays in centiseconds; motion is generated in whole
	##	FRAME_MS units so it quantizes exactly, and the leftover on a one-off
	##	pause is worth less than the frame it would take to correct.
	def __init__(self):
		self.frames, self.durs = [], []
		self._lastBytes = None

	def add(self, img, ms):
		dur = max(20, round(ms / 10.0) * 10)
		raw = img.tobytes()                  # kept: the held frame is re-compared every add
		if raw == self._lastBytes:
			self.durs[-1] += dur
		else:
			self.frames.append(img)
			self.durs.append(dur)
			self._lastBytes = raw


def fMain() -> None:
	ap = argparse.ArgumentParser(add_help=True)
	ap.add_argument("--scenario", required=True)
	ap.add_argument("--out", required=True)
	ap.add_argument("--bin", default="")
	ap.add_argument("--seed", type=int, default=None)
	ap.add_argument("--font", default="")
	ap.add_argument("--quiet", action="store_true")
	args = ap.parse_args()

	sc = fLoadScenario(args.scenario)
	rng = random.Random(args.seed if args.seed is not None else sc.get("seed", 11))
	prog = sc.get("prog", "prog")
	binpath = args.bin or sc.get("bin", prog)

	prefs = [args.font] if args.font else sc.get("font", [])
	prefs = prefs + ["Monaspace Argon SemiBold", "JetBrains Mono",
	                 "Cascadia Mono", "DejaVu Sans Mono"]
	font, fontName = fFindFont([p for p in prefs if p], sc.get("fontsize", 15))

	userTint, hostTint = rng.sample(IDENT_TINTS, 2)
	user = rng.choice(IDENT_USERS)
	host = rng.choice(IDENT_HOSTS)
	prompt = [(user, "user"), ("@", "gray"), (host, "host"), (":", "gray"),
	          ("~", "gray"), ("$ ", "gray")]
	identColors = {"user": userTint, "host": hostTint}

	scr = Screen(font, fontName, sc.get("title", prog), prompt, None, sc.get("fontsize", 15))

	##	Run every command up front: the outputs feed the demo AND tell the
	##	palette which emoji it must include before the first frame renders.
	stepOut = [fRunStep(step, prog, binpath) for step in sc["step"]]
	emojiSet = sorted({ch for lines in stepOut for ln in lines for ch in ln
	                   if scr.fIsEmoji(ch)})
	tiles = [t for t in (scr.fEmojiTile(ch) for ch in emojiSet) if t]
	scr.pal = fBuildPalette(userTint, hostTint, tiles)

	mov = Movie()
	wpmDigits = sc.get("wpm_digits", WPM_DIGITS)
	shown = list(scr.fCursorTarget())    # displayed cursor; glides toward its cell

	def snap(ms, cursor=True):
		mov.add(scr.render(tuple(shown) if cursor else None, identColors), ms)

	def glideCursor(ms):
		##	Slide the shown cursor toward its cell across the keystroke's time,
		##	in whole FRAME_MS frames - the keystroke rounds to the frame grid so
		##	every frame is exactly 2cs. Where it does not actually move (a
		##	thinking pause), the frames are identical and Movie.add folds them up.
		tx, ty = scr.fCursorTarget()
		steps = max(1, round(ms / FRAME_MS))
		x0, y0 = shown
		for s in range(1, steps + 1):
			shown[0] = x0 + (tx - x0) * s / steps
			shown[1] = y0 + (ty - y0) * s / steps
			snap(FRAME_MS)

	def settle(rate, cursor=True):
		##	Smooth-scroll the view to rest; the cursor rides along on its line.
		##	The step is the asked-for rate rounded to an exact divisor of the line
		##	height, so a line boundary never falls mid-step and every frame
		##	advances the same distance - constant velocity is what reads as
		##	smooth, more than raw rate does.
		step = scr.lh / max(1, round(scr.lh / (rate * FRAME_MS / 1000.0)))
		while abs(scr.fRestScroll() - scr.scroll) >= step - 1e-9:
			scr.scroll += step if scr.fRestScroll() > scr.scroll else -step
			shown[:] = scr.fCursorTarget()
			snap(FRAME_MS, cursor)
		scr.scroll = scr.fRestScroll()
		shown[:] = scr.fCursorTarget()

	def holdPause(totalMs):
		##	Idle at the prompt, cursor blinking like a real terminal. One frame
		##	per blink phase and only the block changes, so a long hold still
		##	costs about two small frames a second.
		left, on = float(totalMs), True
		while left > 1e-9:
			span = min(BLINK_MS, left)
			snap(span, on)
			left -= span
			on = not on

	clearBetween = bool(sc.get("clear", True))
	blankAfter = bool(sc.get("blankafter", True))
	snap(700)                                        # opening frame = loop-in target
	for stepIdx, step in enumerate(sc["step"]):
		if clearBetween and stepIdx:
			scr.fClear()
			shown[:] = scr.fCursorTarget()
			snap(220)                                # a beat of empty window
		rate = float(step.get("scrollrate", SCROLL_RATE))
		lineMs = float(step.get("linems", 0))
		notes = step.get("note", [])
		if isinstance(notes, str):
			notes = [notes]
		typeLines = [("# " + n, "dim", WPM_NOTES, False) for n in notes]
		typeLines.append((step["show"].replace("{prog}", prog).replace("{bin}", prog),
		                  "fg", WPM_LETTERS, True))
		for noteOrCmd, key, wpm, typos in typeLines:
			for (action, ch), delay in fTypeEvents(noteOrCmd, rng, wpm, typos, wpmDigits):
				if action == "type":
					scr.typed += ch
				elif action == "bs":
					scr.typed = scr.typed[:-1]
				glideCursor(delay)
			snap(rng.uniform(260, 480) if key == "fg" else 130)   # beat before Enter
			scr.fPut(list(scr.prompt) + [(scr.typed, key)])
			scr.typed = ""
			if key == "dim":                         # notes: no output to run
				if scr.fRestScroll() > scr.scroll + 0.5:
					settle(rate)
				else:
					glideCursor(130)                 # cursor hop onto the new line
				snap(140)
				continue
			##	Prompt stays hidden until the command's output is fully in, the
			##	way a real shell does it.
			scr.showPrompt = False
			if scr.fRestScroll() > scr.scroll + 0.5:
				settle(rate, cursor=False)
			##	A screenful that fits arrives all at once - no frame per line, so
			##	it shows the instant the command does, like a real terminal.
			##	Lines past the bottom are what scroll, and only those.
			outLines = stepOut[stepIdx]
			for ln in outLines:
				scr.fPutText(ln, "fg", step.get("overflow", "truncate"))
				if scr.fRestScroll() > scr.scroll + 0.5:
					settle(rate, cursor=False)
				elif lineMs > 0:
					snap(lineMs, cursor=False)
			if blankAfter and outLines and outLines[-1].strip():
				scr.fPut([("", "fg")])               # breathe before the next prompt
				settle(rate, cursor=False)
			scr.showPrompt = True
			shown[:] = scr.fCursorTarget()
			if scr.fRestScroll() > scr.scroll + 0.5:
				settle(rate)
			snap(60)
			##	Hold past the read time when the window is about to wipe - the
			##	output should not vanish the instant the eye finishes it.
			holdPause(1000 * float(step.get("pause", 2.6))
			           + (CLEAR_HOLD_MS if clearBetween else 0))

	holdPause(1000)                                 # linger, then cut the loop seam

	##	Hard cut to black and hold. A crossfade reads nicer but every fade frame
	##	changes every pixel, so it is dozens of full frames the optimizer cannot
	##	diff away - most of the file for a second nobody watches.
	black = mov.frames[0].copy()
	black.putpalette([0] * len(mov.frames[0].getpalette()))
	mov.frames.append(black)
	mov.durs.append(BLACK_HOLD_MS)

	out = Path(args.out)
	out.absolute().parent.mkdir(parents=True, exist_ok=True)
	mov.frames[0].save(out, save_all=True, append_images=mov.frames[1:],
	                   duration=mov.durs, loop=0, optimize=False)
	raw = out.stat().st_size
	opt = fGifsicle(out)
	if not args.quiet:
		secs = sum(mov.durs) / 1000.0
		size = f"{opt // 1024} KiB (from {raw // 1024})" if opt else f"{raw // 1024} KiB"
		print(f"gen-demo-gif: {args.out}: {len(mov.frames)} frames, "
		      f"{secs:.1f}s loop, {size}, font: {fontName}, "
		      f"{scr.cols}x{scr.rows} cells, ident: {user}@{host}")


if __name__ == "__main__":
	fMain()


##	History:
##		- 20260727: v1.7. Cursor blinks while idle again, and glides at sub-pixel
##			resolution; scenario knob blankafter.
##		- 20260727: v1.6. Output that fits arrives at once (linems defaults to 0);
##			scrolling holds a constant px/frame; steady cursor; exact 2cs frames.
##		- 20260726: v1.5. Loop seam cuts to a black hold instead of crossfading;
##			note= takes a list for multi-line commentary.
##		- 20260726: v1.4. 50 fps motion, screen clears between steps (with a
##			longer hold on the output first), gifsicle optimize pass.
##		- 20260713: v1.3. Full-bleed window (thin black border, no shadow),
##			square corners.
##		- 20260711: v1.2. Antialiased text again (ramped 256 palette), color
##			emoji tiles, prompt hidden until output shows, faster typing and
##			scrolling, cell-width wrap.
##		- 20260711: v1.1. Pixel-smooth scrolling and cursor glide; scenario
##			knobs wpm_digits, scrollrate, linems.
##		- 20260711: v1.0. Scenario-driven typing/render/fade engine.
