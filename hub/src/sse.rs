//! Live events: a fan-out to SSE clients that never blocks on a client.

use std::convert::Infallible;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::response::sse::{Event, KeepAlive, Sse};
use serde_json::Value;
use tokio::sync::mpsc::{self, error::TrySendError};
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::{Stream, StreamExt};

/// Events buffered per client before it is dropped (the page reconnects).
pub const CLIENT_QUEUE: usize = 200;
const PING: Duration = Duration::from_secs(15);

/// `(event kind, JSON data)`
type Message = (&'static str, Arc<str>);

#[derive(Default)]
pub struct Broker {
    clients: Mutex<Vec<mpsc::Sender<Message>>>,
}

impl Broker {
    fn subscribe(&self) -> mpsc::Receiver<Message> {
        let (tx, rx) = mpsc::channel(CLIENT_QUEUE);
        self.clients
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(tx);
        rx
    }

    /// Send to every client; one whose queue is full or that went away is dropped.
    pub fn publish(&self, kind: &'static str, data: &Value) {
        let data: Arc<str> = data.to_string().into();
        self.clients
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|tx| match tx.try_send((kind, data.clone())) {
                Ok(()) => true,
                Err(TrySendError::Full(_) | TrySendError::Closed(_)) => false,
            });
    }

    /// End every stream (on shutdown), so the server can finish.
    pub fn close(&self) {
        self.clients
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }

    /// The SSE response: `retry: 3000`, then events, with a `: ping` comment every 15 s.
    pub fn stream(&self) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
        let rx = self.subscribe();
        let first = tokio_stream::once(Ok(Event::default().retry(Duration::from_millis(3000))));
        let events = ReceiverStream::new(rx)
            .map(|(kind, data)| Ok(Event::default().event(kind).data(data.as_ref())));
        Sse::new(first.chain(events)).keep_alive(KeepAlive::new().interval(PING).text("ping"))
    }
}
