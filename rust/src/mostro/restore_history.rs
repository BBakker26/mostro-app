//! What a restore says is still in progress, and what to make of the rest.
//!
//! After a restore the kind-14 filter covers every recovered trade key, and
//! the relays replay the whole history: each old `new-order`, take and
//! payment message rebuilds a trade row as if it were current. mostrod's
//! restore reply is the authority on what is not history: it lists every
//! order of this identity outside `expired`, `success`, `canceled`,
//! `dispute`, and the admin/cooperative endings (mostro `src/db.rs`,
//! `EXCLUDED_ORDER_STATUSES`) — pending ones included — plus the disputes
//! still open. Every trade this client starts after the restore uses a trade
//! index above the resync floor, so "at or below the floor and not listed"
//! singles out history without trusting any timestamp.
//!
//! History is then settled against the order's public Kind 38383 event: a
//! seller learns of its own completion only there (the daemon sends
//! `PurchaseCompleted` to the buyer alone).

use std::collections::HashSet;

use crate::api::types::OrderStatus;

/// Settings key the snapshot of the last restore is stored under.
pub const SNAPSHOT_KEY: &str = "restore_snapshot";

/// What the last restore reported as still in progress.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct RestoreSnapshot {
    /// The trade-key counter the restore resynced to: every trade started
    /// afterwards has an index above it.
    pub floor: u32,
    /// Order ids the daemon returned, from its orders and open disputes.
    pub live: HashSet<String>,
}

impl RestoreSnapshot {
    /// True when the trade on [order_id] with [trade_index] predates the
    /// restore and the daemon no longer counts it as in progress.
    pub fn is_history(&self, order_id: &str, trade_index: u32) -> bool {
        trade_index <= self.floor && !self.live.contains(order_id)
    }
}

/// What to do with a history row, given its order's public status.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryAction {
    /// The public book says `success`: keep the row, as completed.
    MarkSuccess,
    /// Ended any other way (canceled, expired, or still reading as live on
    /// the book while the daemon says otherwise): drop the row.
    Wipe,
    /// No public answer: leave it for the next pass.
    Retry,
}

/// Decide a history row's fate from its order's public status.
pub fn history_action(public: Option<&OrderStatus>) -> HistoryAction {
    match public {
        Some(OrderStatus::Success) => HistoryAction::MarkSuccess,
        Some(_) => HistoryAction::Wipe,
        None => HistoryAction::Retry,
    }
}

/// True for a row that still reads as in progress: the rows a history pass
/// has to settle. Finished rows already say what happened.
pub fn reads_in_progress(status: &OrderStatus) -> bool {
    !matches!(
        status,
        OrderStatus::Success
            | OrderStatus::Canceled
            | OrderStatus::Expired
            | OrderStatus::CooperativelyCanceled
            | OrderStatus::CanceledByAdmin
            | OrderStatus::SettledByAdmin
            | OrderStatus::CompletedByAdmin
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot() -> RestoreSnapshot {
        RestoreSnapshot {
            floor: 97,
            live: ["disputed-order".to_string()].into_iter().collect(),
        }
    }

    #[test]
    fn an_old_trade_the_daemon_did_not_return_is_history() {
        assert!(snapshot().is_history("old-order", 40));
        assert!(snapshot().is_history("old-order", 97));
    }

    #[test]
    fn a_trade_the_daemon_returned_is_not_history() {
        assert!(!snapshot().is_history("disputed-order", 16));
    }

    #[test]
    fn a_trade_started_after_the_restore_is_not_history() {
        // Its index is above the floor, whatever the daemon returned.
        assert!(!snapshot().is_history("new-order", 98));
    }

    #[test]
    fn the_snapshot_survives_a_round_trip_through_settings() {
        let json = serde_json::to_string(&snapshot()).unwrap();
        let back: RestoreSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(back, snapshot());
    }

    #[test]
    fn a_public_success_keeps_the_row_as_completed() {
        assert_eq!(
            history_action(Some(&OrderStatus::Success)),
            HistoryAction::MarkSuccess
        );
    }

    #[test]
    fn any_other_public_status_drops_the_row() {
        for status in [
            OrderStatus::Canceled,
            OrderStatus::Expired,
            OrderStatus::Pending,
            OrderStatus::InProgress,
        ] {
            assert_eq!(history_action(Some(&status)), HistoryAction::Wipe);
        }
    }

    #[test]
    fn no_public_answer_leaves_the_row_for_the_next_pass() {
        assert_eq!(history_action(None), HistoryAction::Retry);
    }

    #[test]
    fn only_rows_still_reading_as_in_progress_need_settling() {
        assert!(reads_in_progress(&OrderStatus::Pending));
        assert!(reads_in_progress(&OrderStatus::SettledHoldInvoice));
        assert!(reads_in_progress(&OrderStatus::Dispute));
        assert!(!reads_in_progress(&OrderStatus::Success));
        assert!(!reads_in_progress(&OrderStatus::Canceled));
    }
}
