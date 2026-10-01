use crate::async_executor::{AsyncExecutorDriver, EXECUTOR};
use crate::logger::GodotLogWriter;
use crate::ws::{GodotWebsocket, GodotWebsocketFactory};
use flexi_logger::LogSpecBuilder;
use gdnative::{init::InitializeInfo, prelude::*};

mod async_executor;
mod error;
mod logger;
mod ws;

static mut INITIALIZED_LOGGING: bool = false;

struct GdnativeWebsocketLibrary;

#[gdnative::init::callbacks]
impl GDNativeCallbacks for GdnativeWebsocketLibrary {
    fn gdnative_init(_info: InitializeInfo) {
        let logging_initialized: bool;
        unsafe {
            logging_initialized = INITIALIZED_LOGGING;
        }
        if !logging_initialized {
            godot_dbg!("Initializing gdnative-yawc-wrapper logging.");
            let mut log_spec_builder = LogSpecBuilder::new();
            let log_spec = log_spec_builder.default(log::LevelFilter::Debug).build();
            let result = flexi_logger::Logger::with(log_spec)
                .log_to_writer(Box::new(GodotLogWriter {}))
                .start();

            match result {
                Ok(_handle) => {}
                Err(error) => godot_error!("Failed to initialize the Rust logger: {}", error),
            };
            unsafe {
                INITIALIZED_LOGGING = true;
            }
        }
    }
    fn nativescript_init(handle: InitHandle) {
        log::info!("Initializing nativescript");
        gdnative::tasks::register_runtime(&handle);
        gdnative::tasks::set_executor(EXECUTOR.with(|e| *e));

        handle.add_class::<GodotWebsocket>();
        handle.add_class::<GodotWebsocketFactory>();
        handle.add_class::<AsyncExecutorDriver>();
    }
}
