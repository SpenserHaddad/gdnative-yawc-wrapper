use std::{cell::RefCell, sync::Arc};

use gdnative::prelude::*;
use gdnative::tasks::Context;
use yawc::{MaybeTlsStream, Options, WebSocket};

use crate::error::Error;

#[derive(NativeClass)]
#[inherit(Reference)]
#[register_with(Self::register_signals)]
pub struct GodotWebsocket {
    ws: RefCell<Option<WebSocket<MaybeTlsStream<tokio::net::TcpStream>>>>,
}

#[methods]
impl GodotWebsocket {
    fn register_signals(_builder: &ClassBuilder<Self>) {}
    fn new(_owner: TRef<Reference>) -> Self {
        GodotWebsocket {
            ws: RefCell::new(None),
        }
    }

    #[method(async)]
    fn connect_ws(
        #[self] this: Instance<Self>,
        url: String,
    ) -> impl std::future::Future<Output = Result<(), Error>> + 'static {
        async move {
            let url = url.parse::<url::Url>()?;

            let options = Options::default()
                .with_balanced_compression()
                .with_utf8()
                .with_limits(10 * 1024 * 1024, 20 * 1024 * 1024);
            let ws = WebSocket::connect(url).with_options(options).await.ok();
            unsafe { this.assume_safe() }.map(|s, _| s.ws.replace(ws))?;
            Ok(())
        }
    }
}
