use crate::error::Error;
use futures::SinkExt;
use gdnative::core_types::VariantType::GodotString as GodotStringVariant;
use gdnative::prelude::*;
use tokio::{sync::mpsc::error::TryRecvError, task::JoinHandle};
use yawc::{Frame, MaybeTlsStream, Options, WebSocket};

extern crate alloc;

const DEFAULT_MAX_PAYLOAD: usize = 100 * 1024 * 1024;
const DEFAULT_MAX_BUFFER: usize = 200 * 1024 * 1024;

async fn websocket_read_write(
    mut ws: WebSocket<MaybeTlsStream<tokio::net::TcpStream>>,
    inbound_tx: tokio::sync::mpsc::UnboundedSender<Frame>,
    mut outbound_rx: tokio::sync::mpsc::UnboundedReceiver<Frame>,
) -> Result<(), Error> {
    log::info!("Starting WS Tx/Rx loop.");
    loop {
        tokio::select! {
            received_frame = ws.next_frame() => {

                match received_frame {
                    Ok(frame) => {
                        if let Err(error) = inbound_tx.send(frame) {
                            log::error!("Error enqueuing received message: {:?}", error);
                            break;
                        }
                    }
                    Err(error) => {
                        log::error!("Error waiting for frame: {:?}", error);
                        break;
                    }
                }
            }

            send_frame = outbound_rx.recv() => {
                if let Some(frame) = send_frame {
                    match ws.send(frame).await {
                        Ok(()) => (),
                        Err(_) => (),
                    }
                }
            }
        }
    }
    log::info!("Exiting WS Tx/Rx loop");
    ws.close().await?;
    Ok(())
}

#[derive(NativeClass)]
#[inherit(Reference)]
pub struct GodotWebsocketFactory {
    connect_options: Options,
}

#[methods]
impl GodotWebsocketFactory {
    fn new(_owner: TRef<Reference>) -> Self {
        GodotWebsocketFactory {
            connect_options: yawc::Options::default()
                .with_high_compression()
                .with_utf8()
                .with_limits(DEFAULT_MAX_PAYLOAD, DEFAULT_MAX_BUFFER),
        }
    }

    #[method(async)]
    fn connect_to_url(
        #[self] this: Instance<Self>,
        url: String,
    ) -> impl std::future::Future<Output = Result<Instance<GodotWebsocket, Shared>, Error>> + 'static
    {
        log::info!("Connecting to URL: {}", url);

        async move {
            let url = url.parse::<url::Url>()?;

            let options = unsafe { this.assume_safe() }.map(|s, _| s.connect_options.clone())?;
            let ws = WebSocket::connect(url.clone())
                .with_options(options)
                .await?;

            log::info!("Websocket Connected");
            let (inbound_tx, inbound_rx) = tokio::sync::mpsc::unbounded_channel();
            let (outbound_tx, outbound_rx) = tokio::sync::mpsc::unbounded_channel();
            let job = tokio::task::spawn(websocket_read_write(ws, inbound_tx, outbound_rx));
            let ws = GodotWebsocket {
                url: url,
                inbound_rx: inbound_rx,
                outbound_tx: outbound_tx,
                ws_job: job,
            };
            Ok(ws.emplace().into_shared())
        }
    }

    #[method]
    fn set_buffers(&mut self, max_payload: usize, max_buffer: usize) {
        log::info!("set_buffers: max_payload={max_payload}, max_buffer={max_buffer}");
        self.connect_options = self
            .connect_options
            .clone()
            .with_limits(max_payload, max_buffer);
    }
}

#[derive(NativeClass, ToVariant)]
#[no_constructor]
#[inherit(Reference)]
#[register_with(Self::register_signals)]
pub struct GodotWebsocket {
    #[variant(to_variant_with = "url::Url::to_string")]
    url: url::Url,
    #[variant(skip)]
    ws_job: JoinHandle<Result<(), Error>>,
    #[variant(skip)]
    inbound_rx: tokio::sync::mpsc::UnboundedReceiver<Frame>,
    #[variant(skip)]
    outbound_tx: tokio::sync::mpsc::UnboundedSender<Frame>,
}

// impl ToVariant for GodotWebsocket {
//     fn to_variant(&self) -> Variant {
//         struct Output {
//             url: String,
//         }
//         let o = Output {
//             url: self.url.to_string(),
//         };
//         Variant::from(o)`
//     }
// }

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

    #[method]
    fn get_connection_status(&self) -> bool {
        true
    }

    // #[method(async)]
    // fn connect_to_url(
    //     #[self] this: Instance<Self>,
    //     url: String,
    // ) -> impl std::future::Future<Output = Result<(), Error>> + 'static {
    //     log::info!("Connecting to URL: {}", url);

    //     async move {
    //         let url = url.parse::<url::Url>()?;

    //         let options = unsafe { this.assume_safe() }.map(|s, _| s.ws_options.clone())?;
    //         let ws = WebSocket::connect(url).with_options(options).await?;

    //         log::info!("Websocket Connected");
    //         let (inbound_tx, inbound_rx) = tokio::sync::mpsc::unbounded_channel();
    //         let (outbound_tx, outbound_rx) = tokio::sync::mpsc::unbounded_channel();
    //         let job = tokio::task::spawn(websocket_read_write(ws, inbound_tx, outbound_rx));
    //         unsafe { this.assume_safe() }.map_mut(|s, _| {
    //             if let Some(ref job) = s.ws_job {
    //                 job.abort();
    //             }
    //             s.ws_job = Some(job);
    //             s.inbound_rx = Some(inbound_rx);
    //             s.outbound_tx = Some(outbound_tx)
    //         })?;
    //         Ok(())
    //     }
    // }

    #[method]
    fn disconnect_from_host(&self) -> Result<(), Error> {
        if !self.ws_job.is_finished() {
            self.ws_job.abort();
            Ok(())
        } else {
            Err(Error::NotConnected)
        }
    }

    #[method]
    fn set_write_mode(&self, _mode: String) -> Result<(), Error> {
        match self.get_connection_status() {
            true => Err(Error::ChangeSettingsWhileConnected),
            false => Ok(()),
        }
    }

    #[method(async)]
    fn send(
        #[self] this: Instance<Self>,
        data: String,
    ) -> impl std::future::Future<Output = Result<(), Error>> + 'static {
        log::info!("Sending command");
        async move {
            log::info!("(Send) Getting queue...");
            unsafe { this.assume_safe() }.map_mut(|s, _| {
                log::info!("(Send) Enqueuing frame");
                let frame = Frame::text(data);
                s.outbound_tx.send(frame)?;
                log::info!("(Send) Enqueued frame");
                Ok(())
            })?
        }
    }

    #[method(async)]
    fn poll(
        #[self] this: Instance<Self>,
    ) -> impl std::future::Future<Output = Result<(), Error>> + 'static {
        async move {
            unsafe { this.assume_safe() }.map_mut(|s, _| {
                loop {
                    match s.inbound_rx.try_recv() {
                        Ok(frame) => {
                            let base = unsafe { this.assume_safe() }.base();
                            match frame.opcode() {
                                yawc::OpCode::Ping => {}
                                yawc::OpCode::Pong => {}
                                yawc::OpCode::Continuation => {
                                    log::debug!("Got continuation frame");
                                }
                                yawc::OpCode::Close => {
                                    base.emit_signal("connection_closed", &[]);
                                }
                                yawc::OpCode::Binary => {
                                    log::debug!("Got binary frame");
                                }
                                yawc::OpCode::Text => {
                                    let content = std::str::from_utf8(&frame.payload())?;
                                    log::debug!("Got text frame with size {}", content.len());
                                    base.emit_signal("data_received", &[content.to_variant()]);
                                }
                            }
                        }
                        Err(TryRecvError::Empty) => break,
                        Err(TryRecvError::Disconnected) => {
                            let job_is_finished = unsafe { this.assume_safe() }
                                .map_mut(|s, _| s.ws_job.is_finished())?;
                            log::error!("Queue disconnected, job finished: {:?}", job_is_finished);
                        }
                    }
                }
                Ok(())
            })?
        }
    }
}
