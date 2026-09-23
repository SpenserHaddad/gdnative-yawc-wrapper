//! Bridge Rust logging to Godot's logger. Shamelessy copied from:
//! https://godot-rust.github.io/gdnative-book/recipes/logging.html

use flexi_logger::writers::LogWriter;
use flexi_logger::{DeferredNow, Record};
use gdnative::prelude::*;
use log::LevelFilter;

pub struct GodotLogWriter {}

impl LogWriter for GodotLogWriter {
    fn write(&self, _now: &mut DeferredNow, record: &Record) -> std::io::Result<()> {
        match record.level() {
            // Optionally push the Warnings to the godot_error! macro to display as an error in the Godot editor.
            flexi_logger::Level::Error => godot_error!(
                "{}:{} -- {}",
                record.level(),
                record.target(),
                record.args()
            ),
            // Optionally push the Warnings to the godot_warn!  macro to display as a warning in the Godot editor.
            flexi_logger::Level::Warn => godot_warn!(
                "{}:{} -- {}",
                record.level(),
                record.target(),
                record.args()
            ),
            _ => godot_print!(
                "{}:{} -- {}",
                record.level(),
                record.target(),
                record.args()
            ),
        };
        Ok(())
    }

    fn flush(&self) -> std::io::Result<()> {
        Ok(())
    }

    fn max_log_level(&self) -> LevelFilter {
        LevelFilter::Trace
    }
}
