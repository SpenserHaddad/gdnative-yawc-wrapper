//! Bridge Rust logging to Godot's logger. Shamelessy copied from:
//! https://godot-rust.github.io/gdnative-book/recipes/logging.html

use flexi_logger::writers::LogWriter;
use flexi_logger::{DeferredNow, Record};
use gdnative::prelude::*;
use log::LevelFilter;

pub struct GodotLogWriter {}

impl LogWriter for GodotLogWriter {
    fn write(&self, now: &mut DeferredNow, record: &Record) -> std::io::Result<()> {
        match record.level() {
            flexi_logger::Level::Error => godot_error!(
                "({}) {}:{} -- {}",
                now.format_rfc3339(),
                record.level(),
                record.target(),
                record.args(),
            ),
            flexi_logger::Level::Warn => godot_warn!(
                "({}) {}:{} -- {}",
                now.format_rfc3339(),
                record.level(),
                record.target(),
                record.args(),
            ),
            _ => godot_print!(
                "({}) {}:{} -- {}",
                now.format_rfc3339(),
                record.level(),
                record.target(),
                record.args(),
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
