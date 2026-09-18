//! Read a replaceable event without waiting for the slowest relay.
//!
//! `fetch_events` returns once **every** relay has sent EOSE, so one relay
//! that sits on a REQ holds the answer back for the whole timeout — and at
//! startup the node's Kind 38385 used to cost ten seconds that way while three
//! other relays had answered in a third of one. A replaceable event needs no
//! such quorum: any copy will do, the newest is the right one, and relays that
//! answer at all answer within moments of each other.

use futures_util::{Stream, StreamExt};

use crate::rt::time::{timeout, Duration};

/// The newest of the answers in `answers`: the first one, plus whatever else
/// arrives within `grace` of it. `None` when the stream ends without any.
///
/// `grace` exists for the relay holding a stale copy that answers first; it
/// is counted from the first answer, so a source with nothing to say is
/// bounded by the stream's own timeout, not by this.
/// Two answers with the same stamp are copies of one event as far as a caller
/// here can tell, so the first to arrive stays.
pub(crate) async fn newest_answer<T>(
    mut answers: impl Stream<Item = T> + Unpin,
    grace: Duration,
    stamp: impl Fn(&T) -> u64,
) -> Option<T> {
    let mut newest = answers.next().await?;
    // Elapsing is the expected way out: it means a relay is still silent.
    let _ = timeout(grace, async {
        while let Some(answer) = answers.next().await {
            if stamp(&answer) > stamp(&newest) {
                newest = answer;
            }
        }
    })
    .await;
    Some(newest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;
    use tokio::time::Instant;

    const GRACE: Duration = Duration::from_millis(200);

    /// An answer is `(created_at, label)`.
    type Answer = (u64, &'static str);

    fn stream(rx: mpsc::UnboundedReceiver<Answer>) -> impl Stream<Item = Answer> + Unpin {
        Box::pin(futures_util::stream::unfold(rx, |mut rx| async {
            rx.recv().await.map(|answer| (answer, rx))
        }))
    }

    fn stamp(answer: &Answer) -> u64 {
        answer.0
    }

    #[tokio::test(start_paused = true)]
    async fn returns_without_waiting_for_a_source_that_stays_silent() {
        // Arrange: one relay answers, another holds the stream open for 10 s.
        let (tx, rx) = mpsc::unbounded_channel::<Answer>();
        tx.send((100, "fast")).unwrap();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(10)).await;
            drop(tx);
        });
        let started = Instant::now();

        // Act
        let got = newest_answer(stream(rx), GRACE, stamp).await;

        // Assert
        assert_eq!(got, Some((100, "fast")));
        assert_eq!(started.elapsed(), GRACE);
    }

    #[tokio::test(start_paused = true)]
    async fn a_newer_answer_inside_the_grace_window_wins() {
        // Arrange: the stale copy arrives first.
        let (tx, rx) = mpsc::unbounded_channel::<Answer>();
        tx.send((100, "stale")).unwrap();
        tokio::spawn(async move {
            tokio::time::sleep(GRACE / 2).await;
            tx.send((200, "fresh")).unwrap();
            std::future::pending::<()>().await;
        });

        // Act
        let got = newest_answer(stream(rx), GRACE, stamp).await;

        // Assert
        assert_eq!(got, Some((200, "fresh")));
    }

    #[tokio::test(start_paused = true)]
    async fn an_older_answer_does_not_replace_a_newer_one() {
        // Arrange
        let (tx, rx) = mpsc::unbounded_channel::<Answer>();
        tx.send((200, "fresh")).unwrap();
        tx.send((100, "stale")).unwrap();
        drop(tx);

        // Act
        let got = newest_answer(stream(rx), GRACE, stamp).await;

        // Assert
        assert_eq!(got, Some((200, "fresh")));
    }

    #[tokio::test(start_paused = true)]
    async fn ends_as_soon_as_every_source_has_answered() {
        // Arrange: the stream closes (all EOSE) well inside the window.
        let (tx, rx) = mpsc::unbounded_channel::<Answer>();
        tx.send((100, "only")).unwrap();
        drop(tx);
        let started = Instant::now();

        // Act
        let got = newest_answer(stream(rx), GRACE, stamp).await;

        // Assert
        assert_eq!(got, Some((100, "only")));
        assert_eq!(started.elapsed(), Duration::ZERO);
    }

    #[tokio::test(start_paused = true)]
    async fn no_answer_at_all_is_none() {
        // Arrange
        let (tx, rx) = mpsc::unbounded_channel::<Answer>();
        drop(tx);

        // Act
        let got = newest_answer(stream(rx), GRACE, stamp).await;

        // Assert
        assert_eq!(got, None);
    }
}
