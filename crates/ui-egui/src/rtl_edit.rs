//! A text editor for paragraphs with right-to-left script (Arabic, Persian, Urdu, Hebrew).
//!
//! egui lays text out in logical order: it hands each stretch of right-to-left script to the
//! shaper, which joins the letters and draws the stretch right to left, but it places the
//! stretches and the words between them left to right as they were typed. Its glyph list for a
//! shaped stretch is also not one glyph per character (the shaper's clusters run backwards), so
//! `TextEdit` can't place a caret in Arabic at all.
//!
//! [`layout`] does its own line breaking and Unicode bidirectional ordering (UAX #9): every
//! right-to-left word and every other run is laid out by egui on its own (so letters join), then
//! placed where the bidi algorithm puts it. The caret position before each character is measured
//! from the shaped width of the word's prefix. [`show`] is a small editor on top: the text stays
//! in logical (typing) order, the caret and selection follow the screen, Left and Right move the
//! way the arrows point, and copy, cut, paste, IME commits, Home/End, Up/Down, word deletion and
//! select-all work as in `TextEdit`.

use std::ops::Range;
use std::sync::Arc;

use egui::{Color32, CornerRadius, Event, FontId, Galley, Id, Key, Pos2, Rect, Sense, Vec2, pos2, vec2};
use unicode_bidi::BidiInfo;

/// Letters of the right-to-left scripts.
pub fn is_rtl_script(c: char) -> bool {
    matches!(u32::from(c), 0x0590..=0x08FF | 0xFB1D..=0xFDFF | 0xFE70..=0xFEFC | 0x1_0800..=0x1_0FFF | 0x1_E800..=0x1_EFFF)
}

/// Joiners kept inside a right-to-left word.
fn is_joiner(c: char) -> bool {
    matches!(c, '\u{200C}' | '\u{200D}')
}

fn in_rtl_word(c: char) -> bool {
    is_rtl_script(c) || is_joiner(c)
}

/// Whether `text` needs this editor rather than egui's `TextEdit`.
pub fn needs_bidi(text: &str) -> bool {
    text.chars().any(is_rtl_script)
}

/// One character's place: its row, where the caret goes before and after it, and whether it
/// reads right to left. Its box spans `before`..`after` (in either order).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CharBox {
    pub row: usize,
    pub before: f32,
    pub after: f32,
    pub rtl: bool,
}

impl CharBox {
    pub fn x0(&self) -> f32 {
        self.before.min(self.after)
    }
    pub fn x1(&self) -> f32 {
        self.before.max(self.after)
    }
}

/// A row: its logical char range (newline excluded), its top and height, and its direction.
#[derive(Clone, Debug, PartialEq)]
pub struct RowInfo {
    pub chars: Range<usize>,
    pub top: f32,
    pub height: f32,
    pub rtl: bool,
    /// Where an empty row's caret sits.
    pub edge: f32,
}

/// Laid-out text: galleys to paint at their positions, a box for every char (newlines get a
/// zero-width box at their row's end), and the rows.
#[derive(Clone, Debug)]
pub struct BidiLayout {
    pub pieces: Vec<(Pos2, Arc<Galley>)>,
    pub boxes: Vec<CharBox>,
    pub rows: Vec<RowInfo>,
    pub size: Vec2,
}

impl BidiLayout {
    /// The row holding caret position `index` (`0..=len`).
    pub fn row_of(&self, index: usize) -> usize {
        self.rows.iter().position(|r| r.chars.contains(&index) || r.chars.end == index).unwrap_or(self.rows.len().saturating_sub(1))
    }

    /// The caret's row and x before character `index` (a char index, `0..=len`).
    pub fn caret(&self, index: usize) -> (usize, f32) {
        let row = self.row_of(index);
        let Some(info) = self.rows.get(row) else { return (0, 0.0) };
        if index < info.chars.end
            && let Some(b) = self.boxes.get(index)
        {
            return (row, b.before);
        }
        if info.chars.end > info.chars.start
            && let Some(b) = self.boxes.get(info.chars.end - 1)
        {
            return (row, b.after);
        }
        (row, info.edge)
    }

    pub fn row_rect(&self, row: usize) -> Rect {
        self.rows.get(row).map_or(Rect::from_min_size(Pos2::ZERO, vec2(0.0, 16.0)), |r| Rect::from_min_size(pos2(0.0, r.top), vec2(self.size.x, r.height)))
    }

    /// The char index whose caret is nearest `pos` (layout coordinates).
    pub fn index_at(&self, pos: Pos2) -> usize {
        let row = self
            .rows
            .iter()
            .enumerate()
            .min_by(|(_, a), (_, b)| distance_y(a.top, a.height, pos.y).total_cmp(&distance_y(b.top, b.height, pos.y)))
            .map_or(0, |(i, _)| i);
        self.nearest_in_row(row, pos.x)
    }

    /// The char index on `row` whose caret is nearest `x`.
    pub fn nearest_in_row(&self, row: usize, x: f32) -> usize {
        let range = self.rows.get(row).map_or(0..0, |r| r.chars.clone());
        (range.start..=range.end).min_by(|a, b| (self.caret(*a).1 - x).abs().total_cmp(&(self.caret(*b).1 - x).abs())).unwrap_or(range.start)
    }

    /// The caret index one step left (`dir < 0`) or right of `index` on screen, crossing to the
    /// neighbouring row at the row's edge.
    pub fn step_visual(&self, index: usize, dir: i32) -> usize {
        let (row, x) = self.caret(index);
        let range = self.rows.get(row).map_or(0..0, |r| r.chars.clone());
        let candidates = (range.start..=range.end).filter(|i| *i != index).map(|i| (i, self.caret(i).1));
        let best = if dir < 0 {
            candidates.filter(|(_, cx)| *cx < x - 0.01).max_by(|a, b| a.1.total_cmp(&b.1))
        } else {
            candidates.filter(|(_, cx)| *cx > x + 0.01).min_by(|a, b| a.1.total_cmp(&b.1))
        };
        if let Some((i, _)) = best {
            return i;
        }
        let rtl = self.rows.get(row).is_some_and(|r| r.rtl);
        let forward = (dir > 0) != rtl;
        if forward { (range.end + 1).min(self.boxes.len()) } else { range.start.saturating_sub(1) }
    }
}

fn distance_y(top: f32, height: f32, y: f32) -> f32 {
    if y < top {
        top - y
    } else if y > top + height {
        y - top - height
    } else {
        0.0
    }
}

fn shaped(fonts: &mut egui::epaint::FontsView<'_>, text: &str, font: &FontId, color: Color32) -> Arc<Galley> {
    fonts.layout_no_wrap(text.to_owned(), font.clone(), color)
}

fn width_of(fonts: &mut egui::epaint::FontsView<'_>, text: &str, font: &FontId) -> f32 {
    if text.is_empty() { 0.0 } else { shaped(fonts, text, font, Color32::WHITE).rect.width() }
}

/// Lay out `text` in `font`, wrapped at `width`, in visual order. Paragraphs take their
/// direction from their first strong character; right-to-left ones are right-aligned.
pub fn layout(ui: &egui::Ui, text: &str, font: &FontId, color: Color32, width: f32) -> BidiLayout {
    ui.fonts_mut(|fonts| layout_in(fonts, text, font, color, width))
}

/// Visual units of one line: logical char ranges (within the paragraph) and whether each is a
/// right-to-left word, left to right on screen.
fn line_units(info: &BidiInfo<'_>, pchars: &[char], pbytes: &[usize], byte_line: Range<usize>) -> Vec<(Range<usize>, bool)> {
    let mut units = Vec::new();
    let Some(p) = info.paragraphs.first() else { return units };
    if byte_line.is_empty() {
        return units;
    }
    let (levels, runs) = info.visual_runs(p, byte_line);
    for run in runs {
        let run_rtl = levels.get(run.start).is_some_and(|l| l.is_rtl());
        let first = pbytes.iter().position(|b| *b >= run.start).unwrap_or(0);
        let last = pbytes.iter().position(|b| *b >= run.end).unwrap_or(pchars.len());
        let mut in_run: Vec<(Range<usize>, bool)> = Vec::new();
        let mut k = first;
        while k < last {
            if pchars.get(k).is_some_and(|c| in_rtl_word(*c)) {
                let s = k;
                while k < last && pchars.get(k).is_some_and(|c| in_rtl_word(*c)) {
                    k += 1;
                }
                in_run.push((s..k, true));
            } else if run_rtl {
                in_run.push((k..k + 1, false));
                k += 1;
            } else {
                // A left-to-right run is laid out whole.
                let s = k;
                while k < last && !pchars.get(k).is_some_and(|c| in_rtl_word(*c)) {
                    k += 1;
                }
                in_run.push((s..k, false));
            }
        }
        if run_rtl {
            in_run.reverse();
        }
        units.extend(in_run);
    }
    units
}

/// Break a paragraph into lines between words (greedy); a word wider than the line keeps a line
/// of its own.
fn break_lines(fonts: &mut egui::epaint::FontsView<'_>, pchars: &[char], font: &FontId, width: f32) -> Vec<Range<usize>> {
    let mut lines = Vec::new();
    let mut line_start = 0usize;
    let mut last_fit = 0usize;
    let mut i = 0usize;
    while i < pchars.len() {
        let mut j = i;
        while j < pchars.len() && !pchars.get(j).is_some_and(|c| c.is_whitespace()) {
            j += 1;
        }
        while j < pchars.len() && pchars.get(j).is_some_and(|c| c.is_whitespace()) {
            j += 1;
        }
        let candidate: String = pchars.get(line_start..j).map(|c| c.iter().collect::<String>()).unwrap_or_default();
        if last_fit > line_start && width_of(fonts, candidate.trim_end(), font) > width {
            lines.push(line_start..last_fit);
            line_start = last_fit;
            continue;
        }
        last_fit = j;
        i = j.max(i + 1);
    }
    lines.push(line_start..pchars.len().max(line_start));
    lines
}

fn layout_in(fonts: &mut egui::epaint::FontsView<'_>, text: &str, font: &FontId, color: Color32, width: f32) -> BidiLayout {
    let chars: Vec<char> = text.chars().collect();
    let line_height = fonts.row_height(font).max(1.0);
    let width = if width.is_finite() && width > 0.0 { width } else { f32::INFINITY };
    let mut boxes = vec![CharBox { row: 0, before: 0.0, after: 0.0, rtl: false }; chars.len()];
    let mut rows: Vec<RowInfo> = Vec::new();
    let mut pieces = Vec::new();
    let mut widest = 0.0f32;
    let mut paragraphs = Vec::new();
    let mut start = 0usize;
    for (i, c) in chars.iter().enumerate() {
        if *c == '\n' {
            paragraphs.push(start..i);
            start = i + 1;
        }
    }
    paragraphs.push(start..chars.len());
    for para in paragraphs {
        let ptext: String = chars.get(para.clone()).map(|c| c.iter().collect()).unwrap_or_default();
        let info = BidiInfo::new(&ptext, None);
        let rtl = info.paragraphs.first().is_some_and(|p| p.level.is_rtl());
        let pchars: Vec<char> = ptext.chars().collect();
        let mut pbytes: Vec<usize> = ptext.char_indices().map(|(b, _)| b).collect();
        pbytes.push(ptext.len());
        for line in break_lines(fonts, &pchars, font, width) {
            let row_index = rows.len();
            let top = row_index as f32 * line_height;
            let byte_line = pbytes.get(line.start).copied().unwrap_or(0)..pbytes.get(line.end).copied().unwrap_or(ptext.len());
            let mut placed: Vec<(Range<usize>, bool, Arc<Galley>)> = Vec::new();
            let mut line_w = 0.0f32;
            for (range, rtl_word) in line_units(&info, &pchars, &pbytes, byte_line) {
                let s: String = pchars.get(range.clone()).map(|c| c.iter().collect()).unwrap_or_default();
                let g = shaped(fonts, &s, font, color);
                line_w += g.rect.width();
                placed.push((range, rtl_word, g));
            }
            let left = if rtl && width.is_finite() { (width - line_w).max(0.0) } else { 0.0 };
            widest = widest.max(line_w);
            let mut x = left;
            for (range, rtl_word, g) in placed {
                let w = g.rect.width();
                if rtl_word {
                    // The caret before each letter: the word's right edge less its share of the
                    // shaped width, shared in proportion to the letters' own advances (a joined
                    // letter's form is narrower or wider than alone, but the order is what counts,
                    // and a shaped prefix can measure as wide as the whole word).
                    let right = x + w;
                    let advances: Vec<f32> = range
                        .clone()
                        .map(|k| pchars.get(k).map_or(0.0, |c| width_of(fonts, &c.to_string(), font)).max(if pchars.get(k).is_some_and(|c| is_joiner(*c)) { 0.0 } else { 0.5 }))
                        .collect();
                    let sum: f32 = advances.iter().sum::<f32>().max(1e-3);
                    let mut done = 0.0f32;
                    let mut before = right;
                    for (n, k) in range.clone().enumerate() {
                        done += advances.get(n).copied().unwrap_or(0.0);
                        let after = (right - w * done / sum).clamp(x, right);
                        if let Some(b) = boxes.get_mut(para.start + k) {
                            *b = CharBox { row: row_index, before, after, rtl: true };
                        }
                        before = after;
                    }
                } else {
                    let glyphs = g.rows.first().map(|r| r.row.glyphs.clone()).unwrap_or_default();
                    let rtl_char = rtl && range.len() == 1;
                    for (n, k) in range.clone().enumerate() {
                        let (a, b) = glyphs.get(n).map_or((w, w), |gl| (gl.pos.x, gl.pos.x + gl.advance_width));
                        let (before, after) = if rtl_char { (x + w, x) } else { (x + a, x + b) };
                        if let Some(bx) = boxes.get_mut(para.start + k) {
                            *bx = CharBox { row: row_index, before, after, rtl: rtl_char };
                        }
                    }
                }
                pieces.push((pos2(x, top), g));
                x += w;
            }
            let edge = if rtl { if width.is_finite() { width } else { line_w } } else { 0.0 };
            rows.push(RowInfo { chars: para.start + line.start..para.start + line.end, top, height: line_height, rtl, edge });
        }
        // The newline after this paragraph: a zero-width box where its row's caret ends.
        if para.end < chars.len()
            && let Some(last) = rows.last().cloned()
        {
            let x = if last.chars.end > last.chars.start { boxes.get(last.chars.end - 1).map_or(last.edge, |b| b.after) } else { last.edge };
            if let Some(b) = boxes.get_mut(para.end) {
                *b = CharBox { row: rows.len() - 1, before: x, after: x, rtl: false };
            }
        }
    }
    let height = rows.len().max(1) as f32 * line_height;
    let w = if width.is_finite() { width } else { widest };
    BidiLayout { pieces, boxes, rows, size: vec2(w.max(widest), height) }
}

/// The editor's caret and selection anchor, as char indices.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct State {
    cursor: usize,
    anchor: usize,
}

/// What [`show`] reports.
pub struct Output {
    pub response: egui::Response,
    /// The selection as a char range (empty when there is only a caret).
    pub selection: Range<usize>,
}

fn byte_at(text: &str, char_index: usize) -> usize {
    text.char_indices().nth(char_index).map_or(text.len(), |(b, _)| b)
}

fn char_len(text: &str) -> usize {
    text.chars().count()
}

/// Remove the chars in `range`, returning the new caret.
fn delete_range(text: &mut String, range: Range<usize>) -> usize {
    let (a, b) = (byte_at(text, range.start), byte_at(text, range.end));
    if a < b && text.is_char_boundary(a) && text.is_char_boundary(b) {
        text.replace_range(a..b, "");
    }
    range.start.min(char_len(text))
}

fn insert(text: &mut String, at: usize, s: &str) -> usize {
    let b = byte_at(text, at);
    if text.is_char_boundary(b) {
        text.insert_str(b, s);
    }
    at.min(char_len(text)) + char_len(s)
}

fn word_start(chars: &[char], index: usize) -> usize {
    let mut i = index.min(chars.len());
    while i > 0 && chars.get(i - 1).is_some_and(|c| c.is_whitespace()) {
        i -= 1;
    }
    while i > 0 && chars.get(i - 1).is_some_and(|c| !c.is_whitespace()) {
        i -= 1;
    }
    i
}

fn word_end(chars: &[char], index: usize) -> usize {
    let mut i = index.min(chars.len());
    while i < chars.len() && chars.get(i).is_some_and(|c| c.is_whitespace()) {
        i += 1;
    }
    while i < chars.len() && chars.get(i).is_some_and(|c| !c.is_whitespace()) {
        i += 1;
    }
    i
}

/// A multi-line bidirectional editor for `text` in `font`, wrapped at `width`.
pub fn show(ui: &mut egui::Ui, id: Id, text: &mut String, font: &FontId, width: f32, color: Color32, caret_color: Color32) -> Output {
    let state_id = id.with("bidi-state");
    let mut state: State = ui.data(|d| d.get_temp(state_id)).unwrap_or(State { cursor: char_len(text), anchor: char_len(text) });
    let len = char_len(text);
    state.cursor = state.cursor.min(len);
    state.anchor = state.anchor.min(len);
    let mut laid = layout(ui, text, font, color, width);
    let size = laid.size.max(vec2(width.max(4.0), 8.0));
    let (rect, _) = ui.allocate_exact_size(size, Sense::hover());
    let mut response = ui.interact(rect, id, Sense::click_and_drag());
    response.widget_info(|| egui::WidgetInfo::text_edit(ui.is_enabled(), "", text.as_str(), ""));
    if response.hovered() {
        ui.ctx().set_cursor_icon(egui::CursorIcon::Text);
    }
    let origin = rect.min;
    if let Some(p) = response.interact_pointer_pos() {
        let index = laid.index_at(pos2(p.x - origin.x, p.y - origin.y));
        if response.double_clicked() {
            let chars: Vec<char> = text.chars().collect();
            state.anchor = word_start(&chars, index);
            state.cursor = word_end(&chars, index);
        } else if response.dragged() && !response.drag_started() {
            state.cursor = index;
        } else if response.drag_started() || response.clicked() || response.is_pointer_button_down_on() {
            state.cursor = index;
            if !ui.input(|i| i.modifiers.shift) {
                state.anchor = index;
            }
        }
        response.request_focus();
    }
    let focused = response.has_focus();
    if focused {
        ui.memory_mut(|m| m.set_focus_lock_filter(id, egui::EventFilter { tab: false, horizontal_arrows: true, vertical_arrows: true, escape: false }));
        let events = ui.input(|i| i.events.clone());
        let mut changed = false;
        for event in events {
            let sel = state.anchor.min(state.cursor)..state.anchor.max(state.cursor);
            match event {
                Event::Text(t) | Event::Paste(t) | Event::Ime(egui::ImeEvent::Commit(t)) => {
                    let t: String = t.chars().filter(|c| !c.is_control() || *c == '\n').collect();
                    if t.is_empty() {
                        continue;
                    }
                    let at = delete_range(text, sel);
                    state.cursor = insert(text, at, &t);
                    state.anchor = state.cursor;
                    changed = true;
                }
                Event::Copy | Event::Cut => {
                    if !sel.is_empty() {
                        let (a, b) = (byte_at(text, sel.start), byte_at(text, sel.end));
                        if let Some(s) = text.get(a..b) {
                            ui.ctx().copy_text(s.to_owned());
                        }
                        if matches!(event, Event::Cut) {
                            state.cursor = delete_range(text, sel);
                            state.anchor = state.cursor;
                            changed = true;
                        }
                    }
                }
                Event::Key { key, pressed: true, modifiers, .. } => {
                    let word = modifiers.command || modifiers.alt;
                    let chars: Vec<char> = text.chars().collect();
                    let mut moved = None;
                    match key {
                        Key::Backspace => {
                            let range = if !sel.is_empty() {
                                sel
                            } else if word {
                                word_start(&chars, state.cursor)..state.cursor
                            } else {
                                state.cursor.saturating_sub(1)..state.cursor
                            };
                            state.cursor = delete_range(text, range);
                            state.anchor = state.cursor;
                            changed = true;
                        }
                        Key::Delete => {
                            let range = if !sel.is_empty() {
                                sel
                            } else if word {
                                state.cursor..word_end(&chars, state.cursor)
                            } else {
                                state.cursor..(state.cursor + 1).min(chars.len())
                            };
                            state.cursor = delete_range(text, range);
                            state.anchor = state.cursor;
                            changed = true;
                        }
                        Key::Enter if !modifiers.command => {
                            let at = delete_range(text, sel);
                            state.cursor = insert(text, at, "\n");
                            state.anchor = state.cursor;
                            changed = true;
                        }
                        Key::A if modifiers.command => {
                            state.anchor = 0;
                            state.cursor = chars.len();
                        }
                        Key::ArrowLeft | Key::ArrowRight => {
                            let dir = if key == Key::ArrowLeft { -1 } else { 1 };
                            if !sel.is_empty() && !modifiers.shift {
                                let (a, b) = (laid.caret(sel.start).1, laid.caret(sel.end).1);
                                moved = Some(if (dir < 0) == (a <= b) { sel.start } else { sel.end });
                            } else if word {
                                let rtl = laid.rows.get(laid.row_of(state.cursor)).is_some_and(|r| r.rtl);
                                let forward = (dir > 0) != rtl;
                                moved = Some(if forward { word_end(&chars, state.cursor) } else { word_start(&chars, state.cursor) });
                            } else {
                                moved = Some(laid.step_visual(state.cursor, dir).min(chars.len()));
                            }
                        }
                        Key::ArrowUp | Key::ArrowDown => {
                            let (row, x) = laid.caret(state.cursor);
                            let target = if key == Key::ArrowUp { row.checked_sub(1) } else { Some(row + 1).filter(|r| *r < laid.rows.len()) };
                            moved = Some(match target {
                                Some(r) => laid.nearest_in_row(r, x),
                                None if key == Key::ArrowUp => 0,
                                None => chars.len(),
                            });
                        }
                        Key::Home | Key::End => {
                            if modifiers.command {
                                moved = Some(if key == Key::Home { 0 } else { chars.len() });
                            } else {
                                let range = laid.rows.get(laid.row_of(state.cursor)).map_or(0..0, |r| r.chars.clone());
                                moved = Some(if key == Key::Home { range.start } else { range.end });
                            }
                        }
                        _ => {}
                    }
                    if let Some(i) = moved {
                        state.cursor = i;
                        if !modifiers.shift {
                            state.anchor = i;
                        }
                    }
                }
                _ => {}
            }
        }
        if changed {
            response.mark_changed();
            laid = layout(ui, text, font, color, width);
        }
    }
    let len = char_len(text);
    state.cursor = state.cursor.min(len);
    state.anchor = state.anchor.min(len);
    let selection = state.anchor.min(state.cursor)..state.anchor.max(state.cursor);
    if !selection.is_empty() {
        let fill = ui.visuals().selection.bg_fill;
        for i in selection.clone() {
            if let Some(b) = laid.boxes.get(i) {
                let r = laid.row_rect(b.row);
                let x1 = b.x1().max(b.x0() + 2.0);
                ui.painter().rect_filled(
                    Rect::from_min_max(pos2(origin.x + b.x0(), origin.y + r.top()), pos2(origin.x + x1, origin.y + r.bottom())),
                    CornerRadius::ZERO,
                    fill,
                );
            }
        }
    }
    for (at, g) in &laid.pieces {
        ui.painter().galley(origin + at.to_vec2(), g.clone(), color);
    }
    if focused {
        let (row, x) = laid.caret(state.cursor);
        let r = laid.row_rect(row);
        let caret = Rect::from_min_size(pos2(origin.x + x, origin.y + r.top()), Vec2::new(1.5, r.height().max(8.0)));
        ui.painter().rect_filled(caret, CornerRadius::ZERO, caret_color);
        ui.ctx().output_mut(|o| {
            o.ime = Some(egui::output::IMEOutput { purpose: Default::default(), rect, cursor_rect: caret, should_interrupt_composition: false })
        });
    }
    ui.data_mut(|d| d.insert_temp(state_id, state));
    Output { response, selection }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn laid(text: &str, width: f32) -> BidiLayout {
        let ctx = egui::Context::default();
        ctx.set_fonts(crate::theme::font_definitions());
        ctx.run_ui(egui::RawInput::default(), |_| {}).drop_without_applying_deltas();
        let mut out = None;
        ctx.run_ui(egui::RawInput::default(), |ui| out = Some(layout(ui, text, &FontId::proportional(16.0), Color32::WHITE, width)))
            .drop_without_applying_deltas();
        out.unwrap()
    }

    #[test]
    fn arabic_words_read_right_to_left_and_the_caret_starts_at_the_right() {
        let text = "سلام عليكم";
        let l = laid(text, 300.0);
        let first = l.boxes[0];
        let second = l.boxes[6];
        assert!(first.x0() > second.x1() - 0.5, "the first word sits to the right: {:?}", l.boxes);
        let (_, start) = l.caret(0);
        let (_, end) = l.caret(text.chars().count());
        assert!(start > end, "start {start} end {end}");
        assert!((start - 300.0).abs() < 1.0, "a right-to-left paragraph is right-aligned: {start}");
    }

    #[test]
    fn carets_inside_an_arabic_word_move_monotonically_leftwards() {
        let l = laid("مرحبا", 200.0);
        let xs: Vec<f32> = (0..=5).map(|i| l.caret(i).1).collect();
        assert!(xs.windows(2).all(|w| w[0] > w[1]), "{xs:?}");
    }

    #[test]
    fn latin_and_digits_inside_arabic_keep_their_order() {
        let text = "العدد 123 و PDF";
        let l = laid(text, 400.0);
        let b = |i: usize| l.boxes[i];
        assert!(b(6).x0() < b(7).x0() && b(7).x0() < b(8).x0(), "123 reads left to right");
        assert!(b(12).x0() < b(13).x0() && b(13).x0() < b(14).x0(), "PDF reads left to right");
        assert!(b(8).x1() <= b(0).x0() + 0.5, "the number is left of the first word");
        assert!(b(14).x1() <= b(6).x0() + 0.5, "PDF is left of the number");
    }

    #[test]
    fn left_to_right_text_is_left_aligned_and_in_order() {
        let l = laid("Hello world", 300.0);
        let xs: Vec<f32> = (0..=11).map(|i| l.caret(i).1).collect();
        assert!(xs.windows(2).all(|w| w[0] < w[1]), "{xs:?}");
        assert!(xs[0].abs() < 0.01);
    }

    #[test]
    fn long_arabic_text_wraps_and_newlines_start_rows() {
        let l = laid("واحد اثنين ثلاثة أربعة خمسة ستة سبعة", 60.0);
        assert!(l.rows.len() > 2, "{:?}", l.rows);
        assert!(l.rows.windows(2).all(|r| r[0].chars.end <= r[1].chars.start));
        let l = laid("سطر\nسطر", 200.0);
        assert_eq!(l.rows.len(), 2);
        assert_eq!(l.row_of(4), 1);
    }

    #[test]
    fn arrow_keys_move_the_way_they_point_in_arabic() {
        let l = laid("سلام", 200.0);
        assert_eq!(l.step_visual(0, -1), 1);
        assert_eq!(l.step_visual(1, 1), 0);
    }

    #[test]
    fn empty_text_has_one_row_and_a_caret() {
        let l = laid("", 100.0);
        assert_eq!(l.rows.len(), 1);
        assert_eq!(l.caret(0).0, 0);
    }

    #[test]
    fn editing_helpers_respect_char_boundaries() {
        let mut s = String::from("سلام");
        let at = insert(&mut s, 2, "ب");
        assert_eq!(s, "سلبام");
        assert_eq!(at, 3);
        assert_eq!(delete_range(&mut s, 1..3), 1);
        assert_eq!(s, "سام");
        assert_eq!(delete_range(&mut s, 5..9), 3);
        assert_eq!(s, "سام");
    }
}
