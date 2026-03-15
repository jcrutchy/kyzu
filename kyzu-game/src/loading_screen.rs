use egui::Color32;

use crate::loading::{BakeProcess, LineKind};

// ──────────────────────────────────────────────────────────────
//   Colours — Linux console aesthetic
// ──────────────────────────────────────────────────────────────

const COL_DONE: Color32 = Color32::from_rgb(80, 200, 80); // green
const COL_WAIT: Color32 = Color32::from_rgb(200, 200, 60); // yellow
const COL_INFO: Color32 = Color32::from_rgb(160, 160, 160); // grey
const COL_ERROR: Color32 = Color32::from_rgb(220, 60, 60); // red
const COL_BG: Color32 = Color32::from_rgb(10, 10, 10); // near black

pub struct LoadingScreen
{
  pub process: BakeProcess,
}

impl LoadingScreen
{
  pub fn new(bake_exe: &str) -> anyhow::Result<Self>
  {
    Ok(Self { process: BakeProcess::spawn(bake_exe)? })
  }

  pub fn is_finished(&self) -> bool
  {
    self.process.finished()
  }

  pub fn render(&self, ctx: &egui::Context)
  {
    let progress = self.process.progress();
    let lines = self.process.lines();

    egui::CentralPanel::default().frame(egui::Frame::default().fill(COL_BG)).show(ctx, |ui| {
      ui.add_space(20.0);

      // ── Title ────────────────────────────────────────────
      ui.vertical_centered(|ui| {
        ui.label(egui::RichText::new("KYZU").size(32.0).color(COL_DONE).monospace());
        ui.label(egui::RichText::new("World Generation").size(14.0).color(COL_INFO).monospace());
      });

      ui.add_space(20.0);

      // ── Progress bar ─────────────────────────────────────
      let bar_width = ui.available_width() - 40.0;
      let filled = bar_width * progress as f32 / 100.0;

      ui.horizontal(|ui| {
        ui.add_space(20.0);
        let (rect, _) = ui.allocate_exact_size(egui::vec2(bar_width, 16.0), egui::Sense::hover());

        // Background
        ui.painter().rect_filled(rect, 2.0, Color32::from_rgb(30, 30, 30));

        // Fill
        let fill_rect =
          egui::Rect::from_min_size(rect.min, egui::vec2(filled.min(bar_width), 16.0));
        ui.painter().rect_filled(fill_rect, 2.0, COL_DONE);

        // Percentage text
        ui.painter().text(
          rect.center(),
          egui::Align2::CENTER_CENTER,
          format!("{}%", progress),
          egui::FontId::monospace(11.0),
          Color32::WHITE,
        );
      });

      ui.add_space(16.0);
      ui.separator();
      ui.add_space(8.0);

      // ── Scrolling console log ─────────────────────────────
      egui::ScrollArea::vertical().stick_to_bottom(true).show(ui, |ui| {
        for line in &lines
        {
          let (prefix, color) = match line.kind
          {
            LineKind::Done => ("[DONE] ", COL_DONE),
            LineKind::Wait => ("[WAIT] ", COL_WAIT),
            LineKind::Info => ("[INFO] ", COL_INFO),
            LineKind::Error => ("[ERROR] ", COL_ERROR),
            LineKind::Progress => ("[PROGRESS] ", COL_INFO),
          };

          ui.label(
            egui::RichText::new(format!("{}{}", prefix, line.message))
              .monospace()
              .size(11.0)
              .color(color),
          );
        }
      });
    });
  }
}
