use gdnative::{core_types::ToVariant, export::user_data::LocalCellError};
use thiserror::Error;
use yawc;

#[derive(Error, Debug)]
pub enum Error {
    #[error("Command run when not connected to server")]
    NotConnected,

    #[error("Invalid URL: {0}")]
    UrlError(#[from] url::ParseError),

    #[error("Error connecting to host: {0}")]
    WebSocketError(#[from] yawc::WebSocketError),

    #[error("Connection error")]
    ConnectionError(#[from] LocalCellError),
}

impl ToVariant for Error {
    fn to_variant(&self) -> gdnative::prelude::Variant {
        self.to_string().to_variant()
    }
}
