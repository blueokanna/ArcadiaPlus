//! Blocking `std::io` streams, seen from async code.
//!
//! [`crate::protocol::io_shim`] solves the opposite problem: it presents an
//! *async* stream to a synchronous protocol core (courierust's), and does so
//! without blocking the runtime. This module is the mirror image, needed since
//! the QUIC transport ([`crate::protocol::quic_client`]) is corduit's, and
//! corduit is deliberately synchronous: `connect` blocks until the handshake
//! completes, and its streams are `std::io::{Read, Write}` that park on a
//! condition variable while the transport's own driver thread moves packets.
//!
//! ```text
//!   ┌── blocking side (dedicated thread) ──┐        ┌── async side ──┐
//!   │  stream.read() → channel send        │  Bytes │  AsyncRead      │
//!   ┤                                      ├───────►│                 │
//!   │  channel recv → stream.write_all()   │ Bytes  │  AsyncWrite     │
//!   └──────────────────────────────────────┘◄───────┤                 │
//!                                                   └─────────────────┘
//! ```
//!
//! Three properties are load-bearing:
//!
//! * **The runtime is never blocked.** All blocking I/O happens on threads this
//!   module owns; the async halves only poll a bounded channel.
//! * **Pumps get their own threads, not tokio's blocking pool.** A pump lives as
//!   long as the stream does, so putting it in the pool would hold a pool slot
//!   for minutes and starve every short-lived blocking call (including the ones
//!   that open the *next* stream). Dedicated threads keep the pool for
//!   short-lived work, exactly like the transport itself does.
//! * **Backpressure is bounded.** A peer that stops reading fills the channel and
//!   the blocking writer parks in `write_all`, so a slow consumer cannot turn
//!   into unbounded memory growth.

use std::future::poll_fn;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use bytes::Bytes;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::mpsc;
use tokio::sync::oneshot;
use tokio_util::sync::PollSender;

/// Bytes read from the blocking side per wake-up.
pub const READ_CHUNK: usize = 32 * 1024;
/// Chunks buffered in each direction before backpressure applies.
pub const CHUNK_DEPTH: usize = 8;

/// What travels on the write channel: bytes, then optionally the FIN.
#[derive(Debug)]
enum WriteItem {
    Data(Bytes),
    Finish,
}

/// A `std::io::Write` that can be told "this stream is complete".
///
/// Implemented by the QUIC send stream, whose `finish()` queues the FIN for the
/// stream; the default implementation just flushes.
pub trait FinishWrite: io::Write + Send + 'static {
    /// Finish the stream after every queued byte has been written.
    fn finish_stream(&mut self) -> io::Result<()> {
        self.flush()
    }
}

/// Spawn a dedicated OS thread for a long-lived blocking pump.
///
/// Deliberately not `spawn_blocking`: these threads live as long as a stream
/// does, and tokio's blocking pool is sized for short-lived work.
fn spawn_pump(name: &str, work: impl FnOnce() + Send + 'static) -> io::Result<()> {
    std::thread::Builder::new()
        .name(name.to_string())
        .spawn(work)
        .map(|_| ())
        .map_err(|error| io::Error::other(format!("cannot start '{name}' thread: {error}")))
}

/// Run a blocking operation that may park for a long time on a dedicated thread.
///
/// Used for transport calls that wait for an unbounded event (a peer opening a
/// stream, a datagram arriving): `spawn_blocking` would hold a pool slot for
/// however long the peer stays quiet.
pub async fn run_blocking_dedicated<T, F>(name: &str, work: F) -> io::Result<T>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    let (tx, rx) = oneshot::channel();
    spawn_pump(name, move || {
        let _ = tx.send(work());
    })?;
    rx.await
        .map_err(|_| io::Error::other(format!("'{name}' thread exited without a result")))
}

/// The async read half of a blocking stream.
pub struct BlockingReader {
    rx: mpsc::Receiver<io::Result<Bytes>>,
    pending: Option<Bytes>,
    done: bool,
}

impl BlockingReader {
    /// Pump `reader` on a dedicated thread until it reports EOF or fails.
    pub fn spawn<R>(mut reader: R) -> io::Result<Self>
    where
        R: io::Read + Send + 'static,
    {
        let (tx, rx) = mpsc::channel::<io::Result<Bytes>>(CHUNK_DEPTH);
        spawn_pump("veloguard-quic-read", move || {
            let mut buf = vec![0u8; READ_CHUNK];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        if tx
                            .blocking_send(Ok(Bytes::copy_from_slice(&buf[..n])))
                            .is_err()
                        {
                            // The async side is gone; nothing left to feed.
                            break;
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => {
                        let _ = tx.blocking_send(Err(error));
                        break;
                    }
                }
            }
        })?;
        Ok(Self {
            rx,
            pending: None,
            done: false,
        })
    }
}

impl AsyncRead for BlockingReader {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();

        if buf.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }

        if let Some(chunk) = this.pending.take() {
            let taken = chunk.len().min(buf.remaining());
            buf.put_slice(&chunk[..taken]);
            if taken < chunk.len() {
                this.pending = Some(chunk.slice(taken..));
            }
            return Poll::Ready(Ok(()));
        }

        if this.done {
            // Report end-of-stream on every later poll: `read` returning 0 is
            // how the copy loops above learn the peer finished.
            return Poll::Ready(Ok(()));
        }

        loop {
            match this.rx.poll_recv(cx) {
                Poll::Ready(Some(Ok(chunk))) => {
                    if chunk.is_empty() {
                        // Nothing to hand out; ask for the next chunk instead of
                        // returning a meaningless zero-length read.
                        continue;
                    }
                    let taken = chunk.len().min(buf.remaining());
                    buf.put_slice(&chunk[..taken]);
                    if taken < chunk.len() {
                        this.pending = Some(chunk.slice(taken..));
                    }
                    return Poll::Ready(Ok(()));
                }
                Poll::Ready(Some(Err(error))) => {
                    this.done = true;
                    return Poll::Ready(Err(error));
                }
                Poll::Ready(None) => {
                    this.done = true;
                    return Poll::Ready(Ok(()));
                }
                Poll::Pending => return Poll::Pending,
            }
        }
    }
}

/// The async write half of a blocking stream.
pub struct BlockingWriter {
    tx: PollSender<WriteItem>,
    finished: bool,
}

impl BlockingWriter {
    /// Pump `writer` on a dedicated thread until the async side finishes or
    /// drops this handle.
    pub fn spawn<W>(mut writer: W) -> io::Result<Self>
    where
        W: FinishWrite,
    {
        let (tx, mut rx) = mpsc::channel::<WriteItem>(CHUNK_DEPTH);
        spawn_pump("veloguard-quic-write", move || {
            while let Some(item) = rx.blocking_recv() {
                match item {
                    WriteItem::Data(bytes) => {
                        if writer.write_all(&bytes).is_err() {
                            return;
                        }
                    }
                    WriteItem::Finish => break,
                }
            }
            // Reached on an explicit finish *and* when the async handle was
            // dropped: both mean "no more bytes", so queue the FIN (which is
            // what the peer waits for to see a half-close).
            let _ = writer.flush();
            let _ = writer.finish_stream();
        })?;
        Ok(Self {
            tx: PollSender::new(tx),
            finished: false,
        })
    }

    /// Queue the FIN after every byte written so far.
    pub async fn finish(&mut self) -> io::Result<()> {
        if self.finished {
            return Ok(());
        }
        let tx = &mut self.tx;
        poll_fn(move |cx| match tx.poll_reserve(cx) {
            Poll::Ready(Ok(())) => {
                let _ = tx.send_item(WriteItem::Finish);
                Poll::Ready(())
            }
            // The pump is gone (stream failed, connection closed): there is
            // nothing left to finish, and the peer learns about it from the
            // connection error instead.
            Poll::Ready(Err(_)) => Poll::Ready(()),
            Poll::Pending => Poll::Pending,
        })
        .await;
        // Only after the FIN is queued, so a cancelled `finish` does not look
        // like a completed one — and a dropped handle still finishes the
        // stream through the pump's exit path.
        self.finished = true;
        Ok(())
    }

    /// Whether [`Self::finish`] was called.
    pub fn is_finished(&self) -> bool {
        self.finished
    }
}

impl AsyncWrite for BlockingWriter {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        if buf.is_empty() {
            return Poll::Ready(Ok(0));
        }
        let this = self.get_mut();
        if this.finished {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "stream already finished",
            )));
        }

        match this.tx.poll_reserve(cx) {
            Poll::Ready(Ok(())) => match this
                .tx
                .send_item(WriteItem::Data(Bytes::copy_from_slice(buf)))
            {
                Ok(()) => Poll::Ready(Ok(buf.len())),
                Err(_) => Poll::Ready(Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "the blocking writer has stopped",
                ))),
            },
            Poll::Ready(Err(_)) => Poll::Ready(Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "the blocking writer has stopped",
            ))),
            Poll::Pending => Poll::Pending,
        }
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        // Bytes are handed to the pump as soon as they are accepted, and the
        // transport flushes on its own schedule; there is nothing to await here.
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if this.finished {
            return Poll::Ready(Ok(()));
        }
        match this.tx.poll_reserve(cx) {
            Poll::Ready(Ok(())) => {
                let _ = this.tx.send_item(WriteItem::Finish);
                this.finished = true;
                Poll::Ready(Ok(()))
            }
            Poll::Ready(Err(_)) => {
                this.finished = true;
                Poll::Ready(Ok(()))
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Blocking side of the test pipe: `write` feeds the async reader.
    struct PipeWriter {
        tx: std::sync::mpsc::Sender<Vec<u8>>,
        finished: Arc<AtomicBool>,
        fail: bool,
    }

    impl io::Write for PipeWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            if self.fail {
                return Err(io::Error::other("pipe is broken"));
            }
            self.tx
                .send(buf.to_vec())
                .map_err(|_| io::Error::other("pipe reader is gone"))?;
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl FinishWrite for PipeWriter {
        fn finish_stream(&mut self) -> io::Result<()> {
            self.finished.store(true, Ordering::SeqCst);
            Ok(())
        }
    }

    /// Blocking side of the test pipe: `read` blocks until the async writer
    /// hands it a chunk, then reports EOF.
    struct PipeReader {
        rx: std::sync::mpsc::Receiver<Vec<u8>>,
        buf: Vec<u8>,
        pos: usize,
        fail: bool,
    }

    impl io::Read for PipeReader {
        fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
            if self.fail {
                return Err(io::Error::other("pipe is broken"));
            }
            if self.pos == self.buf.len() {
                match self.rx.recv() {
                    Ok(chunk) => {
                        self.buf = chunk;
                        self.pos = 0;
                    }
                    // The sender went away: end of stream.
                    Err(_) => return Ok(0),
                }
            }
            let available = self.buf.len() - self.pos;
            let taken = available.min(out.len());
            out[..taken].copy_from_slice(&self.buf[self.pos..self.pos + taken]);
            self.pos += taken;
            Ok(taken)
        }
    }

    /// One test pipe: the blocking pair plus the handles the test drives it
    /// with.
    ///
    /// Two channels, each in the direction the test needs:
    /// * `observed` — what the blocking writer received, so the test can assert
    ///   on the bytes and their order.
    /// * `feed` — what the test hands to the blocking reader.
    struct TestPipe {
        writer: PipeWriter,
        observed: std::sync::mpsc::Receiver<Vec<u8>>,
        reader: PipeReader,
        feed: std::sync::mpsc::Sender<Vec<u8>>,
        finished: Arc<AtomicBool>,
    }

    fn pipe() -> TestPipe {
        // Blocking side → test.
        let (observed_tx, observed_rx) = std::sync::mpsc::channel();
        // Test → blocking side.
        let (feed_tx, feed_rx) = std::sync::mpsc::channel();
        let finished = Arc::new(AtomicBool::new(false));
        TestPipe {
            writer: PipeWriter {
                tx: observed_tx,
                finished: Arc::clone(&finished),
                fail: false,
            },
            observed: observed_rx,
            reader: PipeReader {
                rx: feed_rx,
                buf: Vec::new(),
                pos: 0,
                fail: false,
            },
            feed: feed_tx,
            finished,
        }
    }

    /// Wait for a chunk, failing instead of hanging when the bridge is broken.
    fn next_chunk(receiver: &std::sync::mpsc::Receiver<Vec<u8>>) -> Vec<u8> {
        receiver
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("the blocking side must receive the bytes")
    }

    #[tokio::test]
    async fn writes_reach_the_blocking_side_in_order() {
        let pipe = pipe();
        let mut async_writer = BlockingWriter::spawn(pipe.writer).expect("writer");

        async_writer.write_all(b"first ").await.expect("write");
        async_writer.write_all(b"second").await.expect("write");
        async_writer.finish().await.expect("finish");

        assert_eq!(next_chunk(&pipe.observed), b"first ");
        assert_eq!(next_chunk(&pipe.observed), b"second");
    }

    #[tokio::test]
    async fn finishing_marks_the_blocking_stream_complete() {
        let pipe = pipe();
        let mut async_writer = BlockingWriter::spawn(pipe.writer).expect("writer");
        async_writer.write_all(b"payload").await.expect("write");
        async_writer.finish().await.expect("finish");

        // The pump calls `finish_stream` after the last byte.
        for _ in 0..100 {
            if pipe.finished.load(Ordering::SeqCst) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert!(
            pipe.finished.load(Ordering::SeqCst),
            "FIN must reach the stream"
        );
    }

    #[tokio::test]
    async fn dropping_the_writer_still_finishes_the_stream() {
        let pipe = pipe();
        {
            let mut async_writer = BlockingWriter::spawn(pipe.writer).expect("writer");
            async_writer.write_all(b"bye").await.expect("write");
        }

        for _ in 0..100 {
            if pipe.finished.load(Ordering::SeqCst) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert!(
            pipe.finished.load(Ordering::SeqCst),
            "a dropped handle must still half-close the stream"
        );
    }

    #[tokio::test]
    async fn bytes_arrive_from_the_blocking_side() {
        let pipe = pipe();
        let mut async_reader = BlockingReader::spawn(pipe.reader).expect("reader");

        pipe.feed.send(b"hello ".to_vec()).expect("send");
        pipe.feed.send(b"world".to_vec()).expect("send");
        drop(pipe.feed);

        let mut out = Vec::new();
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            async_reader.read_to_end(&mut out),
        )
        .await
        .expect("read must not hang")
        .expect("read");
        assert_eq!(out, b"hello world");
    }

    #[tokio::test]
    async fn eof_from_the_blocking_side_ends_the_async_read() {
        let pipe = pipe();
        let mut async_reader = BlockingReader::spawn(pipe.reader).expect("reader");
        drop(pipe.feed);

        let mut buf = [0u8; 8];
        let n = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            async_reader.read(&mut buf),
        )
        .await
        .expect("read must not hang")
        .expect("read");
        assert_eq!(n, 0, "a closed blocking stream reads as EOF");
    }

    #[tokio::test]
    async fn read_errors_surface_then_read_as_eof() {
        let mut pipe = pipe();
        pipe.reader.fail = true;
        let mut async_reader = BlockingReader::spawn(pipe.reader).expect("reader");

        let mut buf = [0u8; 8];
        let error = async_reader.read(&mut buf).await.expect_err("an error");
        assert!(error.to_string().contains("pipe is broken"));

        let n = async_reader.read(&mut buf).await.expect("read after error");
        assert_eq!(n, 0);
    }

    #[tokio::test]
    async fn writing_after_finish_is_refused() {
        let pipe = pipe();
        let mut async_writer = BlockingWriter::spawn(pipe.writer).expect("writer");
        async_writer.finish().await.expect("finish");

        let error = async_writer
            .write_all(b"late")
            .await
            .expect_err("writing after FIN must fail");
        assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
    }

    #[tokio::test]
    async fn dedicated_threads_deliver_their_result() {
        let value = run_blocking_dedicated("test-dedicated", || 7u8 * 6)
            .await
            .expect("result");
        assert_eq!(value, 42);
    }
}
