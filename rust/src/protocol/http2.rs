//! HTTP/2 streams driven by the in-house protocol core.
//!
//! The transports this engine serves — VMess' `h2`, VLESS' `h2`, and gRPC —
//! all have the same shape: *one* request stream whose payload is a raw byte
//! pipe, carried over a connection the caller already established (a TLS
//! session, a WebSocket, a hop through another outbound). Any client that
//! insists on owning its own connection is ruled out by that, because the
//! stream is not ours to open.
//!
//! So the HTTP/2 machinery comes from `courierust_h2`, whose connection type is
//! generic over any `Read + Write` and owns the frame codec, HPACK, flow
//! control, priorities and error handling. This module supplies the three
//! things that crate deliberately does not:
//!
//! 1. **An asynchronous face** — callers use `AsyncRead`/`AsyncWrite` while the
//!    core stays synchronous, bridged by [`crate::protocol::io_shim`] without
//!    ever blocking a runtime worker.
//! 2. **A driver thread** that owns the connection: it applies queued writes,
//!    advances the protocol and forwards stream events. It sleeps on a signal
//!    that both commands and inbound bytes raise, so an idle stream costs
//!    nothing and a busy one is never delayed by a timer.
//! 3. **Honest backpressure** — the command queue is bounded by a semaphore
//!    whose permits the driver returns as it consumes them, and a payload that
//!    stalls on the peer's flow-control window fails after a deadline instead of
//!    spinning.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};

use bytes::Bytes;
use courierust::courierust_h2::connection::{Config, Connection, Event};
use courierust::courierust_hpack::{HeaderField, HeaderList};
use courierust::courierust_io::{Read, Write};
use parking_lot::{Condvar, Mutex};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::mpsc::{
    UnboundedReceiver, UnboundedSender, error::TryRecvError, unbounded_channel,
};

use super::io_shim::DuplexShim;
use super::transport::{Result, TransportError};

/// How long a write may stall on the peer's flow-control window before the call
/// fails. A window shut this long means the peer stopped reading.
const FLOW_CONTROL_DEADLINE: Duration = Duration::from_secs(30);

/// How long the driver sleeps when nothing is happening. Commands and inbound
/// bytes both interrupt it immediately, so this only bounds the idle case.
const IDLE_TICK: Duration = Duration::from_millis(200);

/// How many bytes may be queued for the driver before `poll_write` applies
/// backpressure. The driver itself also refuses data the peer's window cannot
/// take, so this only bounds the window between the caller and the driver.
const WRITE_QUEUE_LIMIT: usize = 4 * 1024 * 1024;

/// A byte-budget gate between the asynchronous writer and the driver.
///
/// `poll_write` adds to `queued` and parks when the budget is gone; the driver
/// subtracts as it hands bytes to the protocol and wakes the parked task. That
/// keeps a stalled peer from turning into unbounded memory without spinning.
#[derive(Default)]
struct WriteGate {
    queued: AtomicUsize,
    waker: Mutex<Option<Waker>>,
}

impl WriteGate {
    fn try_reserve(&self, bytes: usize) -> bool {
        let mut current = self.queued.load(Ordering::Acquire);
        loop {
            if current + bytes > WRITE_QUEUE_LIMIT {
                return false;
            }
            match self.queued.compare_exchange_weak(
                current,
                current + bytes,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return true,
                Err(observed) => current = observed,
            }
        }
    }

    fn release(&self, bytes: usize) {
        self.queued.fetch_sub(
            bytes.min(self.queued.load(Ordering::Acquire)),
            Ordering::AcqRel,
        );
        if let Some(waker) = self.waker.lock().take() {
            waker.wake();
        }
    }

    fn park(&self, waker: &Waker) {
        *self.waker.lock() = Some(waker.clone());
    }
}

/// Commands the asynchronous side sends to the driver.
enum Command {
    /// "Look at the socket" — raised by the shim's reader task whenever bytes
    /// land, so one signal covers both directions.
    Bytes,
    /// Open the request stream and send its header block.
    Headers {
        fields: HeaderList,
        end_stream: bool,
    },
    /// Queue payload bytes.
    Data { bytes: Bytes, end_stream: bool },
}

/// Events the driver forwards to the asynchronous side.
enum SessionEvent {
    /// The response header block for our stream, with its `:status`.
    ResponseHeaders(u16),
    /// Payload bytes.
    Data(Bytes),
    /// The peer ended the stream.
    EndStream,
    /// The stream was reset with `code`.
    Reset { code: u32 },
    /// The session is over; the string says why.
    Closed(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StreamState {
    /// Request headers are out; the response headers have not arrived.
    AwaitingResponse,
    /// Payload flows in both directions.
    Open,
    /// The stream ended cleanly.
    Ended,
    /// The session failed.
    Failed,
}

/// A signal a driver thread waits on, raised by any producer.
#[derive(Clone, Default)]
struct Signal {
    raised: Arc<(Mutex<bool>, Condvar)>,
}

impl Signal {
    fn raise(&self) {
        let (state, condvar) = &*self.raised;
        *state.lock() = true;
        condvar.notify_one();
    }

    fn wait(&self, timeout: Duration) {
        let (state, condvar) = &*self.raised;
        let mut raised = state.lock();
        if !*raised {
            condvar.wait_for(&mut raised, timeout);
        }
        *raised = false;
    }
}

/// One HTTP/2 request stream over a caller-supplied transport.
pub struct H2Stream {
    status: u16,
    commands: Option<UnboundedSender<Command>>,
    events: UnboundedReceiver<SessionEvent>,
    /// Byte budget shared with the driver.
    gate: Arc<WriteGate>,
    /// Bytes of the current data frame the caller has not consumed.
    buffer: Bytes,
    /// A write that had no budget available yet.
    pending_write: Option<Bytes>,
    state: StreamState,
}

impl H2Stream {
    /// Send the request header block and wait for the response headers.
    ///
    /// `stream` is the transport this stream rides on — typically a TLS
    /// session, or a socket another outbound already tunnelled.
    pub async fn open<S>(stream: S, fields: HeaderList) -> Result<Self>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let (command_tx, mut command_rx) = unbounded_channel::<Command>();
        let signal = Signal::default();
        let gate = Arc::new(WriteGate::default());

        let wake_signal = signal.clone();
        let wake_tx = command_tx.clone();
        let (read_half, write_half, shim) = DuplexShim::new(stream, move || {
            let _ = wake_tx.send(Command::Bytes);
            wake_signal.raise();
        });

        let (event_tx, event_rx) = unbounded_channel();
        let driver_signal = signal;
        let driver_gate = Arc::clone(&gate);

        std::thread::Builder::new()
            .name("veloguard-h2".to_string())
            .spawn(move || {
                let _keep_alive = shim;
                let mut session = Connection::new(
                    read_half,
                    write_half,
                    Config {
                        client: true,
                        ..Config::default()
                    },
                );

                let mut stream_id: Option<u32> = None;
                let mut sent_end = false;

                loop {
                    let mut close_reason: Option<String> = None;

                    // 1. Apply queued work before reading: a write must never
                    //    wait for the peer to say something first.
                    loop {
                        let command = match command_rx.try_recv() {
                            Ok(command) => command,
                            Err(TryRecvError::Empty) => break,
                            Err(TryRecvError::Disconnected) => return,
                        };

                        match command {
                            Command::Bytes => {}
                            Command::Headers { fields, end_stream } => {
                                match session.open_request(Default::default()) {
                                    Ok(id) => match session.send_headers(id, &fields, end_stream) {
                                        Ok(()) => {
                                            stream_id = Some(id);
                                            let _ = session.flush();
                                        }
                                        Err(error) => {
                                            close_reason = Some(format!("send_headers: {error}"));
                                            break;
                                        }
                                    },
                                    Err(error) => {
                                        close_reason = Some(format!("open_request: {error}"));
                                        break;
                                    }
                                }
                            }
                            Command::Data { bytes, end_stream } => {
                                let Some(id) = stream_id else {
                                    driver_gate.release(bytes.len());
                                    continue;
                                };

                                let result = send_all(&mut session, id, &bytes);
                                driver_gate.release(bytes.len());

                                match result {
                                    Ok(()) => {
                                        if end_stream && !sent_end {
                                            sent_end = true;
                                            if let Err(error) = session
                                                .send_data(id, courierust::Bytes::new(), true)
                                                .and_then(|_| session.flush())
                                            {
                                                close_reason = Some(format!("end_stream: {error}"));
                                                break;
                                            }
                                        }
                                    }
                                    Err(error) => {
                                        close_reason = Some(error);
                                        break;
                                    }
                                }
                            }
                        }
                    }

                    // 2. Move the protocol forward; would-block is cheap.
                    if close_reason.is_none()
                        && let Err(error) = session.poll_available(16)
                    {
                        close_reason = Some(format!("connection: {error}"));
                    }

                    // 3. Forward events belonging to our stream.
                    while let Some(event) = session.next_event() {
                        match event {
                            Event::Headers {
                                stream_id: id,
                                headers,
                                end_stream,
                                ..
                            } if Some(id) == stream_id => {
                                let status = headers
                                    .iter()
                                    .find(|field| field.name.as_str() == ":status")
                                    .and_then(|field| field.value.to_str().ok())
                                    .and_then(|value| value.parse::<u16>().ok())
                                    .unwrap_or(0);
                                if event_tx
                                    .send(SessionEvent::ResponseHeaders(status))
                                    .is_err()
                                {
                                    return;
                                }
                                if end_stream && event_tx.send(SessionEvent::EndStream).is_err() {
                                    return;
                                }
                            }
                            Event::Data {
                                stream_id: id,
                                data,
                                end_stream,
                            } if Some(id) == stream_id => {
                                if !data.is_empty()
                                    && event_tx
                                        .send(SessionEvent::Data(Bytes::copy_from_slice(&data)))
                                        .is_err()
                                {
                                    return;
                                }
                                if end_stream && event_tx.send(SessionEvent::EndStream).is_err() {
                                    return;
                                }
                            }
                            Event::StreamError {
                                stream_id: id,
                                error_code,
                                ..
                            } if Some(id) == stream_id => {
                                let _ = event_tx.send(SessionEvent::Reset {
                                    code: error_code as u32,
                                });
                            }
                            Event::GoAway { .. } => {
                                close_reason = Some("peer sent GOAWAY".to_string());
                                break;
                            }
                            _ => {}
                        }
                    }

                    if let Some(reason) = close_reason {
                        let _ = event_tx.send(SessionEvent::Closed(reason));
                        return;
                    }

                    // 4. Sleep until a command or an inbound byte arrives.
                    driver_signal.wait(IDLE_TICK);
                }
            })
            .map_err(|error| TransportError::H2(format!("h2 driver thread failed: {error}")))?;

        let mut stream = Self {
            status: 0,
            commands: Some(command_tx),
            events: event_rx,
            gate,
            buffer: Bytes::new(),
            pending_write: None,
            state: StreamState::AwaitingResponse,
        };

        stream
            .send_command(Command::Headers {
                fields,
                end_stream: false,
            })
            .await?;

        loop {
            match stream.events.recv().await {
                Some(SessionEvent::ResponseHeaders(status)) => {
                    stream.status = status;
                    stream.state = StreamState::Open;
                    return Ok(stream);
                }
                Some(SessionEvent::EndStream) => {
                    stream.state = StreamState::Ended;
                    return Ok(stream);
                }
                Some(SessionEvent::Reset { code }) => {
                    stream.state = StreamState::Failed;
                    return Err(TransportError::H2(format!("stream reset ({code})")));
                }
                Some(SessionEvent::Closed(reason)) => {
                    stream.state = StreamState::Failed;
                    return Err(TransportError::H2(reason));
                }
                Some(SessionEvent::Data(_)) => {}
                None => {
                    stream.state = StreamState::Failed;
                    return Err(TransportError::H2("h2 driver stopped".to_string()));
                }
            }
        }
    }

    /// The response `:status`, or `0` when the peer sent none.
    pub fn status(&self) -> u16 {
        self.status
    }

    async fn send_command(&self, command: Command) -> Result<()> {
        match self.commands.as_ref() {
            Some(commands) => commands
                .send(command)
                .map_err(|_| TransportError::H2("h2 driver is gone".to_string())),
            None => Err(TransportError::H2("h2 driver is gone".to_string())),
        }
    }

    /// Queue `bytes`, if the byte budget allows; otherwise park the writer.
    fn try_queue(&mut self, cx: &mut Context<'_>, bytes: Bytes, end_stream: bool) -> Poll<bool> {
        let Some(commands) = self.commands.as_ref() else {
            return Poll::Ready(false);
        };

        if !self.gate.try_reserve(bytes.len()) {
            self.gate.park(cx.waker());
            return Poll::Pending;
        }

        match commands.send(Command::Data { bytes, end_stream }) {
            Ok(()) => Poll::Ready(true),
            Err(_) => Poll::Ready(false),
        }
    }
}

/// Send `bytes` in full, letting the protocol progress when the peer's window is
/// the limiting factor. Credit returns as WINDOW_UPDATE frames, so the
/// connection has to be polled between attempts.
fn send_all(
    session: &mut Connection<impl Read, impl Write>,
    stream_id: u32,
    bytes: &Bytes,
) -> std::result::Result<(), String> {
    let deadline = Instant::now() + FLOW_CONTROL_DEADLINE;
    let mut sent = 0usize;

    while sent < bytes.len() {
        let accepted = session
            .send_data(stream_id, courierust::Bytes::from(&bytes[sent..]), false)
            .map_err(|error| error.to_string())?;

        if accepted == 0 {
            session
                .poll_available(8)
                .map_err(|error| error.to_string())?;
            if Instant::now() > deadline {
                return Err("peer stopped granting flow-control credit".to_string());
            }
            continue;
        }

        sent += accepted;
    }

    session.flush().map_err(|error| error.to_string())
}

impl AsyncRead for H2Stream {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        if !self.buffer.is_empty() {
            let take = self.buffer.len().min(buf.remaining());
            buf.put_slice(&self.buffer[..take]);
            self.buffer = self.buffer.slice(take..);
            return Poll::Ready(Ok(()));
        }

        match self.state {
            StreamState::Ended => return Poll::Ready(Ok(())),
            StreamState::Failed => {
                return Poll::Ready(Err(std::io::Error::other("h2 stream failed")));
            }
            _ => {}
        }

        loop {
            match self.events.poll_recv(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(None) => {
                    self.state = StreamState::Ended;
                    return Poll::Ready(Ok(()));
                }
                Poll::Ready(Some(SessionEvent::Data(data))) => {
                    let take = data.len().min(buf.remaining());
                    buf.put_slice(&data[..take]);
                    self.buffer = data.slice(take..);
                    return Poll::Ready(Ok(()));
                }
                Poll::Ready(Some(SessionEvent::EndStream)) => {
                    self.state = StreamState::Ended;
                    return Poll::Ready(Ok(()));
                }
                Poll::Ready(Some(SessionEvent::Reset { code })) => {
                    self.state = StreamState::Failed;
                    return Poll::Ready(Err(std::io::Error::other(format!(
                        "h2 stream reset ({code})"
                    ))));
                }
                Poll::Ready(Some(SessionEvent::Closed(reason))) => {
                    self.state = StreamState::Failed;
                    return Poll::Ready(Err(std::io::Error::other(reason)));
                }
                Poll::Ready(Some(SessionEvent::ResponseHeaders(_))) => {}
            }
        }
    }
}

impl AsyncWrite for H2Stream {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        if buf.is_empty() {
            return Poll::Ready(Ok(0));
        }
        if self.state == StreamState::Failed {
            return Poll::Ready(Err(std::io::Error::other("h2 stream failed")));
        }

        if self.pending_write.is_none() {
            self.pending_write = Some(Bytes::copy_from_slice(buf));
        }
        let data = self.pending_write.take().expect("just stored");

        match self.try_queue(cx, data.clone(), false) {
            Poll::Ready(true) => Poll::Ready(Ok(buf.len())),
            Poll::Ready(false) => Poll::Ready(Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "h2 driver is gone",
            ))),
            Poll::Pending => {
                self.pending_write = Some(data);
                Poll::Pending
            }
        }
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<std::io::Result<()>> {
        // The driver flushes after every command batch.
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<std::io::Result<()>> {
        if self.state == StreamState::Ended {
            return Poll::Ready(Ok(()));
        }

        match self.try_queue(cx, Bytes::new(), true) {
            Poll::Ready(true) => {
                self.state = StreamState::Ended;
                Poll::Ready(Ok(()))
            }
            Poll::Ready(false) => Poll::Ready(Ok(())),
            Poll::Pending => Poll::Pending,
        }
    }
}

impl Drop for H2Stream {
    fn drop(&mut self) {
        // Dropping the sender ends the driver: it sees the disconnect on its
        // next iteration and returns, which drops the shim and both pump tasks.
        // No join here — `Drop` must not block, and joining from an async
        // context could deadlock the driver.
        self.commands = None;
    }
}

/// Build the header block for a request stream.
pub fn request_fields(
    authority: &str,
    path: &str,
    method: &str,
    extra: &[(&str, &str)],
) -> HeaderList {
    use courierust::courierust_http::{HeaderName, HeaderValue};

    // Pseudo-headers are not ordinary names: `from_hpack_bytes` is the
    // constructor that accepts a leading colon, `from_static` deliberately does
    // not.
    let pseudo = |name: &'static str| {
        HeaderName::from_hpack_bytes(name.as_bytes())
            .expect("`:method`, `:scheme`, `:authority` and `:path` are valid pseudo names")
    };

    let mut fields = vec![
        HeaderField::new(pseudo(":method"), HeaderValue::from(method.to_string())),
        HeaderField::new(pseudo(":scheme"), HeaderValue::from_static("https")),
        HeaderField::new(
            pseudo(":authority"),
            HeaderValue::from(authority.to_string()),
        ),
        HeaderField::new(pseudo(":path"), HeaderValue::from(path.to_string())),
    ];

    for (name, value) in extra {
        if let (Ok(name), Ok(value)) = (
            name.parse::<HeaderName>(),
            HeaderValue::from_bytes(value.as_bytes()),
        ) {
            fields.push(HeaderField::new(name, value));
        }
    }

    fields
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_fields_start_with_the_pseudo_headers() {
        let fields = request_fields("example.com:443", "/x", "POST", &[("x-test", "1")]);
        let names: Vec<&str> = fields.iter().map(|field| field.name.as_str()).collect();
        assert_eq!(&names[..4], [":method", ":scheme", ":authority", ":path"]);
        assert!(names.contains(&"x-test"));
        assert_eq!(fields.len(), 5);
    }

    #[test]
    fn invalid_extra_headers_are_dropped_rather_than_panicking() {
        let fields = request_fields("example.com:443", "/", "GET", &[("bad header", "v")]);
        assert_eq!(fields.len(), 4);
    }

    #[test]
    fn signal_wakes_a_waiting_thread() {
        let signal = Signal::default();
        let raiser = signal.clone();
        let handle = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            raiser.raise();
        });

        let start = Instant::now();
        signal.wait(Duration::from_secs(5));
        assert!(start.elapsed() < Duration::from_secs(4));
        handle.join().expect("raiser thread");
    }
}
