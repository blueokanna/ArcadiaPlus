//! A synchronous `Read + Write` view over an asynchronous stream.
//!
//! `courierust`'s protocol cores are synchronous: they take `Read`/`Write`,
//! own their state machine and never mention an async runtime. Everything above
//! this crate is asynchronous, because the streams a proxy hands around are
//! tokio streams — possibly TLS, possibly tunnelled through another outbound.
//! `tokio_util::io::SyncIoBridge` is the wrong meeting point: it blocks the
//! calling thread inside the runtime, so a slow peer parks a worker and the
//! synchronous side can never poll.
//!
//! This shim moves the bytes instead:
//!
//! ```text
//!        ┌────────── reader task ──────────┐        ┌── synchronous side ──┐
//! async  │  stream.read() → inbound ring    │  Read  │  would-block when    │
//! stream ┤                                  ├───────►│  the ring is empty   │
//!        │  outbound ring → stream.write()  │  Write │  blocks only when    │
//!        └────────── writer task ──────────┘◄───────┤  the ring is full    │
//!                                                   └──────────────────────┘
//! ```
//!
//! Two properties are load-bearing:
//!
//! * **The reader never blocks the synchronous side.** With no bytes buffered,
//!   `read` returns `ErrorKind::WouldBlock`, which is exactly what
//!   `courierust`'s frame readers treat as "no data yet", so a driver loop keeps
//!   servicing its command queue while the peer is silent.
//! * **Both rings are bounded.** A peer that stops reading applies backpressure
//!   to the writer instead of growing memory, and the reader stops prefetching
//!   when the synchronous side has not consumed what it already has.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use courierust::Result as IoResult;
use courierust::courierust_error::{Error, ErrorKind};
use courierust::courierust_io::{Read, Write};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Bytes the reader task may hold before it stops prefetching.
pub const INBOUND_CAPACITY: usize = 256 * 1024;

/// Bytes the synchronous side may queue before `write` applies backpressure.
pub const OUTBOUND_CAPACITY: usize = 256 * 1024;

/// How long a `write` waits for the writer task to drain before failing.
///
/// A safety valve, not a policy: with a live peer the writer task drains
/// continuously, and hitting the ceiling means the peer is not reading at all —
/// where a failed write is more useful than a blocked protocol driver.
const WRITE_STALL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// A callback the reader task raises whenever inbound bytes land, so the
/// driver's single blocking wait covers commands and socket reads alike.
pub type WakeCallback = Arc<dyn Fn() + Send + Sync>;

struct Inbound {
    bytes: VecDeque<u8>,
    eof: bool,
    error: Option<String>,
}

/// Lock a queue, recovering from poisoning.
///
/// These are plain byte buffers: the data behind a poisoned lock is still
/// consistent enough to keep moving bytes, and a single panic in a worker task
/// must not turn every later `lock()` into a panic of its own. (`parking_lot`,
/// used everywhere else in this crate, has no poisoning at all — this keeps the
/// bridge consistent with that.)
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct Outbound {
    bytes: VecDeque<u8>,
    flush_requested: bool,
    flushed: u64,
    closed: bool,
}

struct Shared {
    inbound: Mutex<Inbound>,
    outbound: Mutex<Outbound>,
    /// Signalled when inbound bytes, EOF or an error arrive.
    read_ready: Condvar,
    /// Signalled when outbound space frees up or a flush completes.
    write_ready: Condvar,
    /// Wakes the reader task when the synchronous side consumes bytes.
    drained: tokio::sync::Notify,
    /// Wakes the writer task when the synchronous side queues bytes.
    queued: tokio::sync::Notify,
    /// The writer task stopped (its half of the stream is gone).
    writer_gone: AtomicBool,
}

/// The synchronous handles plus the tasks that feed them.
pub struct DuplexShim {
    state: Arc<Shared>,
    reader_task: tokio::task::JoinHandle<()>,
    #[allow(dead_code)]
    writer_task: tokio::task::JoinHandle<()>,
}

impl DuplexShim {
    /// Wrap `stream`, moving bytes in both directions until either side closes.
    ///
    /// `wake` runs every time inbound bytes arrive, so the caller's blocking
    /// loop waits on one queue instead of on a timer.
    pub fn new<S>(stream: S, wake: impl Fn() + Send + Sync + 'static) -> (ReadHalf, WriteHalf, Self)
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let state = Arc::new(Shared {
            inbound: Mutex::new(Inbound {
                bytes: VecDeque::with_capacity(8 * 1024),
                eof: false,
                error: None,
            }),
            outbound: Mutex::new(Outbound {
                bytes: VecDeque::with_capacity(8 * 1024),
                flush_requested: false,
                flushed: 0,
                closed: false,
            }),
            read_ready: Condvar::new(),
            write_ready: Condvar::new(),
            drained: tokio::sync::Notify::new(),
            queued: tokio::sync::Notify::new(),
            writer_gone: AtomicBool::new(false),
        });

        let (read_side, write_side) = tokio::io::split(stream);
        let wake: WakeCallback = Arc::new(wake);
        let reader_task = tokio::spawn(Self::pump_read(read_side, Arc::clone(&state), wake));
        let writer_task = tokio::spawn(Self::pump_write(write_side, Arc::clone(&state)));

        (
            ReadHalf {
                state: Arc::clone(&state),
            },
            WriteHalf {
                state: Arc::clone(&state),
            },
            Self {
                state,
                reader_task,
                writer_task,
            },
        )
    }

    async fn pump_read<R>(mut reader: R, state: Arc<Shared>, wake: WakeCallback)
    where
        R: AsyncRead + Unpin,
    {
        let mut buffer = vec![0u8; 32 * 1024];
        loop {
            match reader.read(&mut buffer).await {
                Ok(0) => {
                    lock(&state.inbound).eof = true;
                    state.read_ready.notify_all();
                    wake();
                    return;
                }
                Ok(n) => {
                    // Backpressure: stop pulling bytes we cannot hand over.
                    // The guard never spans an await, so the task stays `Send`.
                    while lock(&state.inbound).bytes.len() >= INBOUND_CAPACITY {
                        state.drained.notified().await;
                    }

                    lock(&state.inbound).bytes.extend(&buffer[..n]);
                    state.read_ready.notify_all();
                    wake();
                }
                Err(error) => {
                    lock(&state.inbound).error = Some(error.to_string());
                    state.read_ready.notify_all();
                    wake();
                    return;
                }
            }
        }
    }

    async fn pump_write<W>(mut writer: W, state: Arc<Shared>)
    where
        W: AsyncWrite + Unpin,
    {
        enum Action {
            Data(Vec<u8>),
            Flush,
            Shutdown,
            Idle,
        }

        loop {
            // Decide under the lock, act outside it: a guard that lives across
            // an await would make this future non-`Send`.
            let action = {
                let mut outbound = lock(&state.outbound);
                if outbound.closed {
                    Action::Shutdown
                } else if !outbound.bytes.is_empty() {
                    let take = outbound.bytes.len().min(64 * 1024);
                    let chunk: Vec<u8> = outbound.bytes.drain(..take).collect();
                    state.write_ready.notify_all();
                    Action::Data(chunk)
                } else if outbound.flush_requested {
                    outbound.flush_requested = false;
                    outbound.flushed = outbound.flushed.wrapping_add(1);
                    state.write_ready.notify_all();
                    Action::Flush
                } else {
                    Action::Idle
                }
            };

            match action {
                Action::Shutdown => {
                    let _ = writer.shutdown().await;
                    state.writer_gone.store(true, Ordering::SeqCst);
                    state.write_ready.notify_all();
                    return;
                }
                Action::Data(chunk) => {
                    if let Err(error) = writer.write_all(&chunk).await {
                        tracing::debug!("outbound write failed: {error}");
                        let mut outbound = lock(&state.outbound);
                        outbound.closed = true;
                        outbound.bytes.clear();
                        drop(outbound);
                        state.writer_gone.store(true, Ordering::SeqCst);
                        state.write_ready.notify_all();
                        return;
                    }
                }
                Action::Flush => {
                    let _ = writer.flush().await;
                }
                Action::Idle => {
                    state.queued.notified().await;
                }
            }
        }
    }
}

impl Drop for DuplexShim {
    fn drop(&mut self) {
        lock(&self.state.outbound).closed = true;
        self.state.write_ready.notify_all();
        self.reader_task.abort();
    }
}

/// The `Read` half handed to a synchronous protocol driver.
pub struct ReadHalf {
    state: Arc<Shared>,
}

impl Read for ReadHalf {
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        if buf.is_empty() {
            return Ok(0);
        }

        let mut inbound = lock(&self.state.inbound);

        if !inbound.bytes.is_empty() {
            let take = inbound.bytes.len().min(buf.len());
            for slot in buf.iter_mut().take(take) {
                *slot = inbound.bytes.pop_front().expect("length checked");
            }
            drop(inbound);
            // Room for the reader task to prefetch again.
            self.state.drained.notify_one();
            return Ok(take);
        }

        if let Some(error) = inbound.error.take() {
            return Err(Error::io(error));
        }

        if inbound.eof {
            return Ok(0);
        }

        // "No data yet" — the frame reader treats this as an idle tick.
        Err(Error::new(ErrorKind::WouldBlock))
    }
}

/// The `Write` half handed to a synchronous protocol driver.
pub struct WriteHalf {
    state: Arc<Shared>,
}

impl Write for WriteHalf {
    fn write(&mut self, buf: &[u8]) -> IoResult<usize> {
        let mut outbound = lock(&self.state.outbound);

        if outbound.closed {
            return Err(Error::io("the transport is closed"));
        }

        let deadline = std::time::Instant::now() + WRITE_STALL_TIMEOUT;
        while outbound.bytes.len() >= OUTBOUND_CAPACITY {
            let now = std::time::Instant::now();
            if now >= deadline {
                return Err(Error::with_message(
                    ErrorKind::WouldBlock,
                    "the peer is not reading: outbound buffer stayed full",
                ));
            }
            let (guard, _) = self
                .state
                .write_ready
                .wait_timeout(outbound, deadline - now)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            outbound = guard;
        }

        outbound.bytes.extend(buf);
        drop(outbound);
        // Wake the writer task without waiting for its next poll tick.
        self.state.queued.notify_one();
        Ok(buf.len())
    }

    fn flush(&mut self) -> IoResult<()> {
        let target = {
            let mut outbound = lock(&self.state.outbound);
            outbound.flush_requested = true;
            outbound.flushed.wrapping_add(1)
        };
        self.state.write_ready.notify_all();
        self.state.queued.notify_one();

        // Best effort: wait for the writer task to see and honour the request.
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(500);
        let mut guard = lock(&self.state.outbound);
        loop {
            if guard.flushed == target {
                break;
            }
            let now = std::time::Instant::now();
            if now >= deadline {
                break;
            }
            let (next, _) = self
                .state
                .write_ready
                .wait_timeout(guard, deadline - now)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            guard = next;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use tokio::net::{TcpListener, TcpStream};

    #[tokio::test]
    async fn bytes_cross_the_boundary_in_both_directions() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept");
            let mut buffer = [0u8; 5];
            socket.read_exact(&mut buffer).await.expect("read");
            assert_eq!(&buffer, b"hello");
            socket.write_all(b"world").await.expect("write");
        });

        let stream = TcpStream::connect(addr).await.expect("connect");
        let woken = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&woken);
        let (mut read_half, mut write_half, _shim) = DuplexShim::new(stream, move || {
            counter.fetch_add(1, Ordering::SeqCst);
        });

        write_half.write(b"hello").expect("write");
        write_half.flush().expect("flush");

        // The reader reports WouldBlock until the peer answers.
        let mut received = Vec::new();
        for _ in 0..200 {
            let mut buffer = [0u8; 5];
            match read_half.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => received.extend_from_slice(&buffer[..n]),
                Err(error) if error.kind == ErrorKind::WouldBlock => {
                    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                }
                Err(error) => panic!("read failed: {error:?}"),
            }
            if received.len() >= 5 {
                break;
            }
        }

        assert_eq!(received, b"world");
        assert!(woken.load(Ordering::SeqCst) > 0, "the reader never woke");
        server.await.expect("server task");
    }

    #[tokio::test]
    async fn eof_is_reported_as_zero_bytes() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.expect("accept");
            drop(socket);
        });

        let stream = TcpStream::connect(addr).await.expect("connect");
        let (mut read_half, _write_half, _shim) = DuplexShim::new(stream, || {});
        server.await.expect("server task");

        for _ in 0..200 {
            let mut buffer = [0u8; 8];
            match read_half.read(&mut buffer) {
                Ok(0) => return,
                Ok(_) => panic!("the peer sent nothing"),
                Err(error) if error.kind == ErrorKind::WouldBlock => {
                    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                }
                Err(error) => panic!("read failed: {error:?}"),
            }
        }

        panic!("EOF was never reported");
    }
}
