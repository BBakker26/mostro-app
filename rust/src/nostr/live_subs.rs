//! Long-lived relay subscriptions that survive a relay being down when they
//! are (re)issued.
//!
//! nostr-sdk 0.45 re-sends a long-lived REQ on every reconnect — but only for
//! a subscription that sits in that relay's registry, and a REQ that fails to
//! send is **removed** from it (`subscribe_long_lived`). A subscribe issued
//! while a relay is disconnected therefore never exists on that relay, not
//! even after it reconnects. Replacing a subscription (CLOSE + REQ) while the
//! pool is offline — which is what a resume does — deletes it everywhere, for
//! the rest of the session: the bulk kind-14 feed died exactly like that, and
//! a buyer never saw the daemon's `add-invoice`.
//!
//! So the intent is recorded here, apart from the SDK's registries, and
//! [`LiveSubs::repair_relay`] re-issues whatever a relay is missing the moment
//! it connects (see [`spawn_repair`]). Rules for callers, also in
//! `docs/RELAYS.md`:
//!
//! - every long-lived subscription goes through [`LiveSubs::open`] or
//!   [`LiveSubs::replace`], never a bare `client.subscribe`;
//! - every `client.unsubscribe` of one goes through [`LiveSubs::close`], or
//!   the repair resurrects it on the next reconnect.

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use anyhow::Result;
use nostr_sdk::prelude::{Client, Filter, RelayStatus, SubscriptionId};

/// What [`LiveSubs::replace`] achieved right now. Either way the intent is
/// recorded and the relays that missed it are repaired when they connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Issued {
    /// At least one relay took the REQ.
    Live,
    /// No relay took it (the pool is offline): it exists nowhere yet.
    Deferred,
}

/// How long one relay may take to accept a repaired REQ.
const REPAIR_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

#[derive(Default)]
pub(crate) struct LiveSubs {
    /// The lock also serializes open/replace/close/repair: a repair slotting
    /// in between a replace's CLOSE and REQ would make that REQ fail with
    /// "subscription ID already exists".
    desired: tokio::sync::Mutex<HashMap<SubscriptionId, Filter>>,
}

/// The process-wide registry every production subscription uses.
pub(crate) fn live_subs() -> &'static LiveSubs {
    static LIVE: OnceLock<LiveSubs> = OnceLock::new();
    LIVE.get_or_init(LiveSubs::default)
}

impl LiveSubs {
    /// Subscribe `filter` under `id`, failing when no relay accepted the REQ.
    ///
    /// For subscriptions whose caller needs coverage *now* (a per-trade
    /// watcher about to publish a request): nothing is recorded on failure.
    /// On success the intent is kept, so the relays that refused are repaired
    /// when they connect.
    pub(crate) async fn open(
        &self,
        client: &Client,
        id: SubscriptionId,
        filter: Filter,
    ) -> Result<()> {
        let mut desired = self.desired.lock().await;
        if issue(client, &id, &filter).await? == Issued::Deferred {
            return Err(anyhow::anyhow!("subscribe {id} rejected by every relay"));
        }
        desired.insert(id, filter);
        Ok(())
    }

    /// Point the long-lived subscription `id` at `filter`, replacing whatever
    /// it carried before.
    ///
    /// nostr-sdk refuses a subscribe whose id already exists and keeps the old
    /// filters, so the id is closed first. The intent is recorded **before**
    /// that CLOSE: with every relay down the REQ lands nowhere, and the record
    /// is what brings the subscription back when they reconnect.
    pub(crate) async fn replace(
        &self,
        client: &Client,
        id: SubscriptionId,
        filter: Filter,
    ) -> Result<Issued> {
        let mut desired = self.desired.lock().await;
        desired.insert(id.clone(), filter.clone());
        if let Err(e) = client.unsubscribe(&id).await {
            log::warn!("[relay] closing {id} before re-subscribing failed: {e}");
        }
        let issued = issue(client, &id, &filter).await?;
        if issued == Issued::Deferred {
            crate::api::logging::blog_warn(
                "relay",
                format!("sub {id} deferred: no relay connected — re-issued on reconnect"),
            );
        }
        Ok(issued)
    }

    /// Close `id` for good: forgets the intent, then drops the relay-side REQ.
    pub(crate) async fn close(&self, client: &Client, id: &SubscriptionId) {
        let mut desired = self.desired.lock().await;
        desired.remove(id);
        if let Err(e) = client.unsubscribe(id).await {
            log::debug!("[relay] unsubscribe {id} failed: {e}");
        }
    }

    /// Re-issue on `url` every recorded subscription that relay does not
    /// hold (or holds with a superseded filter). Returns how many it issued.
    ///
    /// The candidates are snapshotted and the lock is taken again **per
    /// subscription**, so a stalled socket holds up an `open` — a take about
    /// to publish — for one bounded REQ at most, not for the whole sweep.
    /// Each one is re-validated under that lock against what is recorded and
    /// what the relay holds *now*: an `open`, `replace` or `close` that ran in
    /// between wins, and a stale snapshot never overwrites it.
    pub(crate) async fn repair_relay(&self, client: &Client, url: &str) -> usize {
        let Ok(Some(relay)) = client.relay(url).await else {
            return 0;
        };
        let candidates: Vec<SubscriptionId> = {
            let desired = self.desired.lock().await;
            if desired.is_empty() || relay.status() != RelayStatus::Connected {
                return 0;
            }
            missing_on(&desired, &relay.subscriptions().await)
                .into_iter()
                .map(|(id, _)| id)
                .collect()
        };
        let mut issued = 0;
        for id in candidates {
            let desired = self.desired.lock().await;
            let Some(filter) = desired.get(&id).cloned() else {
                continue; // closed since the snapshot
            };
            if relay.status() != RelayStatus::Connected {
                break;
            }
            match relay.subscription(&id).await {
                Some(held) if held.as_slice() == std::slice::from_ref(&filter) => continue,
                // Superseded filter: same "id exists" refusal as in `replace`.
                Some(_) => {
                    let _ = relay.unsubscribe(&id).await;
                }
                None => {}
            }
            let attempt = crate::rt::time::timeout(
                REPAIR_TIMEOUT,
                std::future::IntoFuture::into_future(relay.subscribe(filter).with_id(id.clone())),
            )
            .await
            .map_err(|_| "timed out".to_string())
            .and_then(|sent| sent.map_err(|e| e.to_string()));
            drop(desired);
            match attempt {
                Ok(_) => {
                    issued += 1;
                    crate::api::logging::blog_info(
                        "relay",
                        format!(
                            "sub {id} repaired relay={}",
                            crate::api::logging::display_relay(url)
                        ),
                    );
                }
                Err(e) => crate::api::logging::blog_warn(
                    "relay",
                    format!(
                        "sub {id} repair failed relay={} err={}",
                        crate::api::logging::display_relay(url),
                        crate::api::logging::sanitize_relay_text(&e),
                    ),
                ),
            }
        }
        issued
    }

    /// [`Self::repair_relay`] for every relay of the pool.
    pub(crate) async fn repair_all(&self, client: &Client) -> usize {
        let urls: Vec<String> = client
            .relays()
            .await
            .keys()
            .map(|url| url.to_string())
            .collect();
        let mut issued = 0;
        for url in urls {
            issued += self.repair_relay(client, &url).await;
        }
        issued
    }
}

/// One REQ to every relay of the pool; per-relay refusals are logged.
async fn issue(client: &Client, id: &SubscriptionId, filter: &Filter) -> Result<Issued> {
    let output = client
        .subscribe(filter.clone())
        .with_id(id.clone())
        .await
        .map_err(|e| anyhow::anyhow!("subscribe {id} failed: {e}"))?;
    for (url, err) in &output.failed {
        crate::api::logging::blog_warn(
            "relay",
            format!(
                "sub {id} failed relay={} err={}",
                crate::api::logging::display_relay(&url.to_string()),
                crate::api::logging::sanitize_relay_text(err),
            ),
        );
    }
    Ok(if output.success.is_empty() {
        Issued::Deferred
    } else {
        Issued::Live
    })
}

/// The recorded subscriptions a relay lacks, or holds under another filter.
fn missing_on(
    desired: &HashMap<SubscriptionId, Filter>,
    present: &HashMap<SubscriptionId, Vec<Filter>>,
) -> Vec<(SubscriptionId, Filter)> {
    desired
        .iter()
        .filter(|(id, filter)| {
            present
                .get(*id)
                .is_none_or(|held| held.as_slice() != std::slice::from_ref(*filter))
        })
        .map(|(id, filter)| (id.clone(), filter.clone()))
        .collect()
}

/// Repair a relay's subscriptions whenever the pool's status monitor reports
/// it connected. A lagged receiver may have dropped that report, so it
/// repairs every relay instead.
pub(crate) fn spawn_repair(pool: &Arc<super::relay_pool::RelayPool>) {
    use tokio::sync::broadcast::error::RecvError;

    let mut rx = pool.subscribe_relay_status();
    let client = pool.client();
    crate::rt::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(info) if info.status == crate::api::types::RelayStatus::Connected => {
                    live_subs().repair_relay(&client, &info.url).await;
                }
                Ok(_) => {}
                Err(RecvError::Lagged(_)) => {
                    live_subs().repair_all(&client).await;
                }
                Err(RecvError::Closed) => break,
            }
        }
    });
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use nostr_sdk::local_relay::MockRelay;
    use nostr_sdk::prelude::{Keys, Kind};
    use std::time::Duration;

    fn dm_filter() -> Filter {
        Filter::new()
            .kind(Kind::PrivateDirectMessage)
            .pubkey(Keys::generate().public_key())
    }

    /// The rule that keeps this fix in place (docs/RELAYS.md): a long-lived
    /// subscription opened or closed behind the registry's back is one a
    /// reconnect cannot repair — or one it resurrects.
    #[test]
    fn no_module_subscribes_or_unsubscribes_behind_the_registry() {
        // The NWC client owns a separate `Client` with its own lifecycle.
        const ALLOWED: [&str; 3] = ["nostr/live_subs.rs", "nwc/client.rs", "frb_generated.rs"];

        fn rust_files(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
            for entry in std::fs::read_dir(dir).expect("read src").flatten() {
                let path = entry.path();
                if path.is_dir() {
                    rust_files(&path, out);
                } else if path.extension().is_some_and(|ext| ext == "rs") {
                    out.push(path);
                }
            }
        }

        // Arrange
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = Vec::new();
        rust_files(&src, &mut files);

        // Act
        let offenders: Vec<String> = files
            .iter()
            .filter(|path| !ALLOWED.iter().any(|allowed| path.ends_with(allowed)))
            .flat_map(|path| {
                let text = std::fs::read_to_string(path).expect("read source");
                text.lines()
                    .enumerate()
                    .filter(|(_, line)| {
                        line.contains(".unsubscribe(") || line.contains(".with_id(")
                    })
                    .map(|(n, _)| format!("{}:{}", path.display(), n + 1))
                    .collect::<Vec<_>>()
            })
            .collect();

        // Assert
        assert!(
            offenders.is_empty(),
            "use live_subs().open/replace/close instead of the bare SDK call: {offenders:?}"
        );
    }

    #[test]
    fn missing_on_reports_absent_and_superseded_subscriptions_only() {
        // Arrange
        let kept = SubscriptionId::new("kept");
        let absent = SubscriptionId::new("absent");
        let stale = SubscriptionId::new("stale");
        let (kept_f, absent_f, stale_f) = (dm_filter(), dm_filter(), dm_filter());
        let desired = HashMap::from([
            (kept.clone(), kept_f.clone()),
            (absent.clone(), absent_f),
            (stale.clone(), stale_f),
        ]);
        let present = HashMap::from([(kept, vec![kept_f]), (stale.clone(), vec![dm_filter()])]);

        // Act
        let mut missing: Vec<String> = missing_on(&desired, &present)
            .into_iter()
            .map(|(id, _)| id.to_string())
            .collect();
        missing.sort();

        // Assert
        assert_eq!(missing, vec![absent.to_string(), stale.to_string()]);
    }

    /// The field failure: a resume replaced `mostro-dm` while every relay was
    /// down, and the feed never came back although the relays did.
    #[tokio::test]
    async fn a_subscription_replaced_while_offline_is_reissued_when_the_relay_connects() {
        // Arrange
        let relay = MockRelay::run().await.expect("mock relay");
        let url = relay.url().await;
        let client = Client::new();
        client.add_relay(&url).await.expect("add relay");
        let subs = LiveSubs::default();
        let id = SubscriptionId::new("mostro-dm-test");
        let filter = dm_filter();

        // Act: replaced offline, then the relay connects.
        let issued = subs
            .replace(&client, id.clone(), filter.clone())
            .await
            .expect("an offline replace is deferred, not an error");
        client
            .try_connect_relay(&url, Duration::from_secs(3))
            .await
            .expect("connect");
        let sdk_relay = client
            .relay(&url)
            .await
            .expect("relay")
            .expect("known relay");
        let before_repair = sdk_relay.subscription(&id).await;
        let repaired = subs.repair_relay(&client, url.as_str()).await;

        // Assert
        assert_eq!(issued, Issued::Deferred);
        assert!(
            before_repair.is_none(),
            "the SDK alone does not bring a failed REQ back — that is the bug"
        );
        assert_eq!(repaired, 1);
        assert_eq!(sdk_relay.subscription(&id).await, Some(vec![filter]));
        assert_eq!(
            subs.repair_relay(&client, url.as_str()).await,
            0,
            "idempotent"
        );
    }

    /// A retake supersedes the earlier take's d-tag task under the same id.
    /// Whichever order the two reach the registry in, the newer filter must
    /// own the REQ: `replace` is one critical section, so the older task's
    /// late `open` finds the id taken and fails instead of slotting in
    /// between the newer task's CLOSE and REQ.
    #[tokio::test]
    async fn a_late_open_cannot_take_over_a_replaced_subscription() {
        // Arrange
        let relay = MockRelay::run().await.expect("mock relay");
        let url = relay.url().await;
        let client = Client::new();
        client.add_relay(&url).await.expect("add relay");
        client
            .try_connect_relay(&url, Duration::from_secs(3))
            .await
            .expect("connect");
        let subs = LiveSubs::default();
        let id = SubscriptionId::new("d-tag-test");
        let (older, newer) = (dm_filter(), dm_filter());

        // Act: both race; the older task's open lands last.
        let (replaced, opened) =
            tokio::join!(subs.replace(&client, id.clone(), newer.clone()), async {
                tokio::task::yield_now().await;
                subs.open(&client, id.clone(), older).await
            });

        // Assert
        assert_eq!(replaced.expect("replace"), Issued::Live);
        assert!(opened.is_err(), "the superseded open must not be accepted");
        assert_eq!(
            client.subscription(&id).await.into_values().next(),
            Some(vec![newer.clone()])
        );
        assert_eq!(
            subs.repair_relay(&client, url.as_str()).await,
            0,
            "and the registry agrees with the relay"
        );
    }

    #[tokio::test]
    async fn a_closed_subscription_is_not_resurrected_by_a_repair() {
        // Arrange
        let relay = MockRelay::run().await.expect("mock relay");
        let url = relay.url().await;
        let client = Client::new();
        client.add_relay(&url).await.expect("add relay");
        client
            .try_connect_relay(&url, Duration::from_secs(3))
            .await
            .expect("connect");
        let subs = LiveSubs::default();
        let id = SubscriptionId::new("per-trade-test");
        subs.open(&client, id.clone(), dm_filter())
            .await
            .expect("open");

        // Act
        subs.close(&client, &id).await;
        let repaired = subs.repair_relay(&client, url.as_str()).await;

        // Assert
        assert_eq!(repaired, 0);
        assert!(client.subscription(&id).await.is_empty());
    }

    #[tokio::test]
    async fn open_fails_and_records_nothing_when_no_relay_accepts() {
        // Arrange
        let relay = MockRelay::run().await.expect("mock relay");
        let url = relay.url().await;
        let client = Client::new();
        client.add_relay(&url).await.expect("add relay");
        let subs = LiveSubs::default();
        let id = SubscriptionId::new("per-trade-offline");

        // Act
        let result = subs.open(&client, id, dm_filter()).await;
        client
            .try_connect_relay(&url, Duration::from_secs(3))
            .await
            .expect("connect");

        // Assert
        assert!(result.is_err());
        assert_eq!(subs.repair_relay(&client, url.as_str()).await, 0);
    }
}
