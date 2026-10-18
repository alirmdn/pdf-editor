//! Home tab: a dark hero with Open and Create, quick tools, recent files as cards, and pinned
//! folders (local only, never another app's list).

use egui::{Align2, Color32, CornerRadius, Rect, Sense, Stroke, vec2};
use pdfcraft_engine::catalog;

use crate::theme::{self, Tokens};
use crate::{PdfCraftApp, icons, panels::human_size, widgets};

/// The tools shown as tiles, in order.
const QUICK_TOOLS: [&str; 8] = ["edit", "organize", "fill_sign", "comment", "scan", "protect", "compress", "export"];

/// The widest the content column grows; wider windows centre it.
const MAX_WIDTH: f32 = 1180.0;

/// A soft shadow that rises on hover and settles when the card is pressed.
fn card_lift(ui: &egui::Ui, t: &Tokens, rect: Rect, press: theme::Press) {
    let lift = press.hover * (1.0 - press.down);
    if lift > 0.04 {
        let shadow = egui::Shadow { offset: [0, 4], blur: (18.0 * lift) as u8, spread: 0, color: t.page_shadow.gamma_multiply(0.9 * lift) };
        ui.painter().add(shadow.as_shape(rect, CornerRadius::same(12)));
    }
}

/// `color` mixed into the card colour by `amount`, for the hero glow and icon wells.
fn tint(t: &Tokens, color: Color32, amount: f32) -> Color32 {
    t.card.lerp_to_gamma(color, amount)
}

pub fn show(app: &mut PdfCraftApp, ui: &mut egui::Ui) {
    let t = Tokens::get(ui.ctx());
    egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
        let full = ui.available_width();
        let width = (full.min(MAX_WIDTH) - 64.0).max(200.0);
        let side = ((full - width) / 2.0).clamp(16.0, 120.0);
        egui::Frame::NONE.inner_margin(egui::Margin { left: side as i8, right: side as i8, top: 28, bottom: 32 }).show(ui, |ui| {
            ui.set_width(width);
            hero(app, ui, &t);
            ui.add_space(30.0);
            quick_tools(app, ui, &t);
            ui.add_space(30.0);
            recent(app, ui, &t);
            #[cfg(not(target_arch = "wasm32"))]
            {
                ui.add_space(28.0);
                crate::folders_ui::section(app, ui);
            }
            ui.add_space(28.0);
            ui.label(
                egui::RichText::new(tl!("PDF Editor works offline. No telemetry, no account, and no cloud processing unless you add a provider."))
                    .color(t.text_faint)
                    .font(theme::regular(12.0)),
            );
        });
    });
}

fn hero(app: &mut PdfCraftApp, ui: &mut egui::Ui, t: &Tokens) {
    let frame = egui::Frame::NONE
        .fill(tint(t, t.accent, if t.dark() { 0.10 } else { 0.05 }))
        .stroke(Stroke::new(1.0, tint(t, t.accent, 0.28)))
        .corner_radius(CornerRadius::same(18))
        .inner_margin(egui::Margin { left: 28, right: 28, top: 26, bottom: 24 });
    frame.show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            widgets::app_mark(ui, 56.0);
            ui.add_space(10.0);
            ui.vertical(|ui| {
                ui.label(egui::RichText::new("PDF Editor").font(theme::semibold(28.0)).color(t.text));
                ui.label(
                    egui::RichText::new(tl!("Open, edit and sign PDFs in Arabic and English, privately on this computer."))
                        .color(t.text_muted)
                        .font(theme::regular(14.0)),
                );
            });
        });
        ui.add_space(20.0);
        ui.horizontal_wrapped(|ui| {
            ui.spacing_mut().item_spacing = vec2(10.0, 10.0);
            if widgets::icon_pill(ui, "folder-open", tl!("Open PDF"), true).clicked() {
                app.open_dialog();
            }
            if widgets::icon_pill(ui, "file-plus-2", tl!("Create PDF"), false).clicked() {
                app.select_tool("create");
            }
            if widgets::icon_pill(ui, "files", tl!("Combine files"), false).clicked() {
                app.select_tool("combine");
            }
            if widgets::icon_pill(ui, "file-pen-line", tl!("Edit text"), false).clicked() {
                app.select_tool("edit");
            }
        });
        ui.add_space(12.0);
        ui.label(egui::RichText::new(tl!("Or drop a PDF anywhere in this window.")).color(t.text_faint).font(theme::regular(12.0)));
    });
}

fn heading(ui: &mut egui::Ui, t: &Tokens, text: &str) {
    ui.label(egui::RichText::new(text).font(theme::semibold(17.0)).color(t.text));
    ui.add_space(12.0);
}

fn quick_tools(app: &mut PdfCraftApp, ui: &mut egui::Ui, t: &Tokens) {
    heading(ui, t, tl!("Tools"));
    let gap = 12.0;
    // Eight tiles: one row of eight, two of four, or four of two, never a ragged last row.
    let fits = ((ui.available_width() + gap) / (140.0 + gap)).floor();
    let columns = if fits >= 8.0 { 8.0 } else if fits >= 4.0 { 4.0 } else { 2.0 };
    let tile_w = ((ui.available_width() - gap * (columns - 1.0)) / columns).floor().max(100.0);
    ui.horizontal_wrapped(|ui| {
        ui.spacing_mut().item_spacing = vec2(gap, gap);
        for id in QUICK_TOOLS {
            let Some(g) = catalog::group(id) else { continue };
            let (rect, resp) = ui.allocate_exact_size(vec2(tile_w, 96.0), Sense::click());
            resp.widget_info(|| egui::WidgetInfo::labeled(egui::WidgetType::Button, true, tl!(g.label)));
            let press = theme::Press::track(ui, &resp);
            card_lift(ui, t, rect, press);
            let fill = press.fill(t.card, t.hover, t.pressed);
            ui.painter().rect(rect, CornerRadius::same(12), fill, Stroke::new(1.0, t.border), egui::StrokeKind::Inside);
            let body = rect.translate(press.offset());
            let color = Color32::from_rgb(g.hue[0], g.hue[1], g.hue[2]);
            let well = Rect::from_min_size(body.min + vec2(14.0, 14.0), vec2(34.0, 34.0));
            ui.painter().rect_filled(well, CornerRadius::same(9), tint(t, color, if t.dark() { 0.22 } else { 0.14 }));
            icons::paint(ui, well.shrink(8.0), g.icon, 18.0, color);
            let mut job = egui::text::LayoutJob::simple_singleline(tl!(g.label).to_owned(), theme::semibold(13.5), t.text);
            job.wrap = egui::text::TextWrapping { max_width: body.width() - 28.0, max_rows: 2, break_anywhere: false, ..Default::default() };
            let galley = ui.fonts_mut(|f| f.layout_job(job));
            let elided = galley.elided;
            ui.painter().galley(body.min + vec2(14.0, 58.0), galley, t.text);
            let resp = if elided { resp.on_hover_text(tl!(g.label)) } else { resp };
            if theme::hand(resp).clicked() {
                app.select_tool(g.id);
            }
        }
    });
}

fn recent(app: &mut PdfCraftApp, ui: &mut egui::Ui, t: &Tokens) {
    let mut clear = false;
    ui.horizontal(|ui| {
        ui.label(egui::RichText::new(tl!("Recent")).font(theme::semibold(17.0)).color(t.text));
        if !app.recent.is_empty() {
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let resp = widgets::ghost_button(ui, "trash-2", tl!("Clear"));
                resp.widget_info(|| egui::WidgetInfo::labeled(egui::WidgetType::Button, true, tl!("Clear Recent Files")));
                clear = resp.on_hover_text(tl!("Clear Recent Files")).clicked();
            });
        }
    });
    ui.add_space(12.0);
    if app.recent.is_empty() {
        egui::Frame::NONE
            .fill(t.card)
            .stroke(Stroke::new(1.0, t.border))
            .corner_radius(CornerRadius::same(12))
            .inner_margin(egui::Margin::same(22))
            .show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.label(egui::RichText::new(tl!("Files you open in PDF Editor appear here. Drop a PDF anywhere to open it.")).color(t.text_muted));
            });
    }
    let gap = 12.0;
    let columns = ((ui.available_width() + gap) / (300.0 + gap)).floor().clamp(1.0, 4.0);
    let card_w = ((ui.available_width() - gap * (columns - 1.0)) / columns).floor().max(160.0);
    let mut open = None;
    let mut remove = None;
    ui.horizontal_wrapped(|ui| {
        ui.spacing_mut().item_spacing = vec2(gap, gap);
        for r in &app.recent {
            let (rect, resp) = ui.allocate_exact_size(vec2(card_w, 74.0), Sense::click());
            resp.widget_info(|| egui::WidgetInfo::labeled(egui::WidgetType::Button, true, &r.name));
            let press = theme::Press::track(ui, &resp);
            card_lift(ui, t, rect, press);
            // The card, not its response: the pointer stays "in" the card over its remove button.
            let hovered = ui.rect_contains_pointer(rect);
            let fill = if hovered { press.fill(t.hover, t.hover, t.pressed) } else { t.card };
            ui.painter().rect(rect, CornerRadius::same(12), fill, Stroke::new(1.0, t.border), egui::StrokeKind::Inside);
            let body = rect.translate(press.offset());
            let badge = Rect::from_min_size(body.min + vec2(14.0, 15.0), vec2(36.0, 44.0));
            ui.painter().rect_filled(badge, CornerRadius::same(7), tint(t, t.accent, if t.dark() { 0.30 } else { 0.16 }));
            ui.painter().text(badge.center(), Align2::CENTER_CENTER, "PDF", theme::semibold(10.5), t.accent_text);
            if hovered {
                // Remove just this file from the list (#430); the file itself is untouched.
                let x_rect = Rect::from_center_size(rect.right_top() + vec2(-20.0, 20.0), vec2(26.0, 26.0));
                let x = ui.interact(x_rect, ui.id().with(("remove-recent", &r.path)), Sense::click());
                let label = crate::i18n::fmt(tl!("Remove {name} from Recent"), &[("name", &r.name)]);
                x.widget_info(|| egui::WidgetInfo::labeled(egui::WidgetType::Button, true, &label));
                if x.hovered() {
                    ui.painter().rect_filled(x_rect, CornerRadius::same(6), t.pressed);
                }
                icons::paint(ui, x_rect.shrink(6.0), "x", 14.0, t.icon);
                if x.on_hover_text(tl!("Remove from Recent")).clicked() {
                    remove = Some(r.path.clone());
                }
            }
            let text_x = body.left() + 62.0;
            let width = (body.right() - 40.0 - text_x).max(0.0);
            widgets::row_text(ui, egui::pos2(text_x, body.top() + 22.0), crate::bidi::visual(&r.name), theme::medium(13.5), t.text, width);
            let detail =
                format!("{}  ·  {}", crate::i18n::trn(crate::i18n::current(), r.pages as u64, "{n} page", "{n} pages"), human_size(r.size));
            widgets::row_text(ui, egui::pos2(text_x, body.top() + 40.0), detail, theme::regular(11.5), t.text_muted, width);
            widgets::row_text(ui, egui::pos2(text_x, body.top() + 56.0), crate::bidi::visual(&r.path), theme::regular(10.5), t.text_faint, width);
            if theme::hand(resp).on_hover_text(&r.path).clicked() {
                open = Some(r.path.clone());
            }
        }
    });
    if let Some(p) = open {
        app.open_recent(&p);
    }
    if let Some(p) = remove {
        app.recent.retain(|r| r.path != p);
    }
    if clear {
        app.execute("file.clear_recent");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_offers_open_create_and_the_quick_tools_without_upstream_branding() {
        let ctx = egui::Context::default();
        ctx.set_fonts(theme::font_definitions());
        let mut app = PdfCraftApp::new();
        let output = ctx
            .run_ui(egui::RawInput { screen_rect: Some(Rect::from_min_size(egui::Pos2::ZERO, vec2(1440.0, 900.0))), ..Default::default() }, |ui| {
                show(&mut app, ui)
            });
        let texts: Vec<String> = output
            .shapes
            .iter()
            .filter_map(|shape| if let egui::Shape::Text(text) = &shape.shape { Some(text.galley.job.text.clone()) } else { None })
            .collect();
        output.drop_without_applying_deltas();
        for want in ["Open PDF", "Create PDF", "Tools", "Recent"] {
            assert!(texts.iter().any(|t| t == want), "{want} is on the home screen: {texts:?}");
        }
        for id in QUICK_TOOLS {
            let g = catalog::group(id).unwrap();
            assert!(texts.iter().any(|t| t == g.label), "{} tile", g.label);
        }
        for banned in ["ArtCraft", "Discord", "PdfCraft", "PrintCraft"] {
            assert!(!texts.iter().any(|t| t.contains(banned)), "{banned} must not appear: {texts:?}");
        }
    }
}
