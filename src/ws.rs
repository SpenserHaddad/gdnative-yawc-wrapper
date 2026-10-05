use crate::error::Error;
use futures::SinkExt;
use gdnative::core_types::VariantType::GodotString as GodotStringVariant;
use gdnative::prelude::*;
use std::rc::Rc;
use tokio::{sync::mpsc::error::TryRecvError, task::JoinHandle};
use tokio_util::sync::CancellationToken;
use yawc::{Frame, MaybeTlsStream, Options, WebSocket};

extern crate alloc;

const DEFAULT_MAX_PAYLOAD: usize = 100 * 1024 * 1024;
const DEFAULT_MAX_BUFFER: usize = 200 * 1024 * 1024;

async fn websocket_read_write(
    mut ws: WebSocket<MaybeTlsStream<tokio::net::TcpStream>>,
    inbound_tx: tokio::sync::mpsc::UnboundedSender<Frame>,
    mut outbound_rx: tokio::sync::mpsc::UnboundedReceiver<Frame>,
    cancellation_token: CancellationToken,
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

            _ = cancellation_token.cancelled() => {
                log::info!("Cancellation token cancelled");
                break;
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
            let cancellation_token = tokio_util::sync::CancellationToken::new();
            let job = tokio::task::spawn(websocket_read_write(
                ws,
                inbound_tx,
                outbound_rx,
                cancellation_token.clone(),
            ));
            let ws = GodotWebsocket {
                inbound_rx: inbound_rx,
                outbound_tx: outbound_tx,
                ws_job: Rc::new(job),
                cancellation_token: cancellation_token,
                connected: true,
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
    #[property(get)]
    connected: bool,
    #[variant(skip)]
    ws_job: Rc<JoinHandle<Result<(), Error>>>,
    #[variant(skip)]
    inbound_rx: tokio::sync::mpsc::UnboundedReceiver<Frame>,
    #[variant(skip)]
    outbound_tx: tokio::sync::mpsc::UnboundedSender<Frame>,
    #[variant(skip)]
    cancellation_token: tokio_util::sync::CancellationToken,
}

#[methods]
impl GodotWebsocket {
    fn register_signals(builder: &ClassBuilder<Self>) {
        builder
            .signal("connection_closed")
            .with_param("reason", GodotStringVariant)
            .done();
        builder
            .signal("data_received")
            .with_param("data", GodotStringVariant)
            .done();
    }

    #[method]
    fn disconnect_from_host(&mut self, #[base] owner: &Reference) -> Result<(), Error> {
        if self.connected {
            self._close_connection(owner, "Disconnect requested");
            Ok(())
        } else {
            Err(Error::NotConnected)
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
            unsafe { this.assume_safe() }.map_mut(|s, _| match s.connected {
                true => {
                    log::info!("(Send) Enqueuing frame");
                    let frame = Frame::text(data);
                    s.outbound_tx.send(frame)?;
                    log::info!("(Send) Enqueued frame");
                    Ok(())
                }
                false => Err(Error::NotConnected),
            })?
        }
    }

    fn _close_connection(&mut self, owner: &Reference, reason: impl ToVariant) {
        log::info!("Closing connection");
        self.connected = false;
        self.cancellation_token.cancel();
        owner.emit_signal("connection_closed", &[reason.to_variant()]);
    }

    #[method(async)]
    fn poll(
        #[self] this: Instance<Self>,
    ) -> impl std::future::Future<Output = Result<(), Error>> + 'static {
        async move {
            unsafe { this.assume_safe() }.map_mut(|s, base| {
                //Check if the job unexpectedly finished since the last poll
                if s.connected && s.ws_job.is_finished() {
                    log::info!("Connection closed unexpectedly");
                    s._close_connection(&base, Error::ConnectionClosed);
                }

                if s.connected {
                    loop {
                        match s.inbound_rx.try_recv() {
                            Ok(frame) => match frame.opcode() {
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
                            },
                            Err(TryRecvError::Empty) => break,
                            Err(TryRecvError::Disconnected) => {
                                let job_is_finished = unsafe { this.assume_safe() }
                                    .map_mut(|s, _| s.ws_job.is_finished())?;
                                log::error!(
                                    "Queue disconnected, job finished: {:?}",
                                    job_is_finished
                                );
                            }
                        }
                    }
                }
                Ok(())
            })?
        }
    }
}
