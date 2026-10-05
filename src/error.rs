use gdnative::{core_types::ToVariant, export::user_data::LocalCellError};
use thiserror::Error;
use yawc;

#[derive(Error, Debug)]
pub enum Error {
    #[error("Command run when not connected to server")]
    NotConnected,

    #[error("Cannot change connection settings while connected.")]
    ChangeSettingsWhileConnected,

    #[error("Connection closed unexpectedly")]
    ConnectionClosed,

    #[error("Could not enqueue a frame to send: {0}")]
    SendFrameError(#[from] tokio::sync::mpsc::error::SendError<yawc::Frame>),

    #[error("Invalid URL: {0}")]
    UrlError(#[from] url::ParseError),

    #[error("Error connecting to host: {0}")]
    WebSocketError(#[from] yawc::WebSocketError),

    #[error("Connection error")]
    ConnectionError(#[from] LocalCellError),

    #[error("Failed to parse UTF-8: {0}")]
    Utf8Error(#[from] std::str::Utf8Error),
}

impl ToVariant for Error {
    fn to_variant(&self) -> gdnative::prelude::Variant {
        self.to_string().to_variant()
    }
}
