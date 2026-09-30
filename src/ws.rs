use std::{sync::Arc, time::Duration};

use crate::error::Error;
use futures::{SinkExt, StreamExt};
use gdnative::core_types::VariantType::GodotString as GodotStringVariant;
use gdnative::prelude::*;
use tokio::{sync::Mutex, task::JoinHandle};
use yawc::{Frame, MaybeTlsStream, WebSocket};

const DEFAULT_MAX_PAYLOAD: usize = 1 * 1024 * 1024;
const DEFAULT_MAX_BUFFER: usize = 100 * 1024 * 1024;

#[derive(NativeClass)]
#[inherit(Reference)]
#[register_with(Self::register_signals)]
pub struct GodotWebsocket {
    ws: Arc<tokio::sync::Mutex<Option<WebSocket<MaybeTlsStream<tokio::net::TcpStream>>>>>,
    ws_options: yawc::Options,
    bg_job: Option<JoinHandle<()>>,
    #[property]
    debug_value: i32,
}

async fn task() {
    let mut counter: u128 = 0;
    loop {
        log::info!("Count is {}", counter);
        counter += 1;
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

#[methods]
impl GodotWebsocket {
    fn register_signals(builder: &ClassBuilder<Self>) {
        builder.signal("connection_closed").done();
        builder.signal("connection_established").done();
        builder.signal("connection_error").done();
        builder
            .signal("data_received")
            .with_param("data", GodotStringVariant)
            .done();
    }
    fn new(_owner: TRef<Reference>) -> Self {
        log::info!("Hello from GodotWebsocket!!");
        GodotWebsocket {
            debug_value: 156,
            bg_job: None,
            ws: Arc::new(Mutex::new(None)),
            ws_options: yawc::Options::default()
                .with_high_compression()
                .with_utf8()
                .with_limits(DEFAULT_MAX_PAYLOAD, DEFAULT_MAX_BUFFER),
        }
    }

    #[method]
    fn get_connection_status(&self) -> bool {
        true
    }

    #[method(async)]
    fn connect_to_url(
        #[self] this: Instance<Self>,
        url: String,
    ) -> impl std::future::Future<Output = Result<(), Error>> + 'static {
        log::info!("Connecting to URL: {}", url);

        async move {
            let url = url.parse::<url::Url>()?;

            let options = unsafe { this.assume_safe() }.map(|s, _| s.ws_options.clone())?;
            let ws = WebSocket::connect(url).with_options(options).await?;
            let ws_ac = unsafe { this.assume_safe() }.map_mut(|s, _| s.ws.clone())?;
            let mut w = ws_ac.lock().await;
            *w = Some(ws);

            log::info!("Websocket Connected");
            let job = tokio::task::spawn(task());
            unsafe { this.assume_safe() }.map_mut(|s, _| {
                if let Some(ref job) = s.bg_job {
                    job.abort();
                }
                s.bg_job = Some(job);
            })?;
            Ok(())
        }
    }

    #[method]
    fn disconnect_from_host(&self) -> Result<(), Error> {
        match self.get_connection_status() {
            true => Ok(()),
            false => Err(Error::NotConnected),
        }
    }

    #[method]
    fn set_write_mode(&self, _mode: String) -> Result<(), Error> {
        match self.get_connection_status() {
            true => Err(Error::ChangeSettingsWhileConnected),
            false => Ok(()),
        }
    }

    #[method]
    fn set_buffers(&mut self, max_payload: usize, max_buffer: usize) -> Result<(), Error> {
        log::info!("set_buffers: max_payload={max_payload}, max_buffer={max_buffer}");
        match self.get_connection_status() {
            true => Err(Error::ChangeSettingsWhileConnected),
            false => {
                let new_options = &self.ws_options.clone().with_limits(max_payload, max_buffer);
                self.ws_options = new_options.clone();
                Ok(())
            }
        }
    }

    #[method(async)]
    fn send(
        #[self] this: Instance<Self>,
        data: String,
    ) -> impl std::future::Future<Output = Result<(), Error>> + 'static {
        log::info!("Sending command");
        async move {
            log::info!("(Send) Waiting for ws...");
            if let Some(ws) = unsafe { this.assume_safe() }
                .map_mut(|s, _| s.ws.clone())?
                .lock()
                .await
                .as_mut()
            {
                log::info!("(Send) Websocket Sending");
                let frame = Frame::text(data);
                let _ = ws.send(frame).await?;
                log::info!("(Send) Websocket Sent");
                Ok(())
            } else {
                Err(Error::NotConnected)
            }
        }
    }

    #[method(async)]
    fn poll(
        #[self] this: Instance<Self>,
    ) -> impl std::future::Future<Output = Result<(), Error>> + 'static {
        async move {
            if let Ok(ws) = unsafe { this.assume_safe() }
                .map_mut(|s, _| s.ws.clone())?
                .try_lock()
                .as_mut()
            {
                let peeker = ws.peekable();
                let pinned_peek = std::pin::pin!(peeker);
                if let Some(frame) = pinned_peek.peek().await {
                    // let (opcode, _, body) = frame.into_parts();
                    log::debug!("Got frame with opcode: {:?}", &frame.opcode());
                    let base = unsafe { this.assume_safe() }.base();
                    match frame.opcode() {
                        yawc::OpCode::Ping => {}
                        yawc::OpCode::Pong => {}
                        yawc::OpCode::Continuation => {}
                        yawc::OpCode::Close => {
                            base.emit_signal("connection_closed", &[]);
                        }
                        yawc::OpCode::Binary => {}
                        yawc::OpCode::Text => {
                            let content = std::str::from_utf8(&frame.payload())?;
                            base.emit_signal("data_received", &[content.to_variant()]);
                        }
                    }
                } else {
                    unsafe { this.assume_safe() }
                        .base()
                        .emit_signal("connection_closed", &[]);
                    return Err(Error::ConnectionClosed);
                }
            }
            Ok(())
        }
    }
}
