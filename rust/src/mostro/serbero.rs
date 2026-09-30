//! Serbero, a node's dispute assistant (app#637, mostro#1009).
//!
//! A node that runs Serbero announces its pubkey in the info event (kind
//! 38385) as `["serbero", "<hex>"]`, and registers it as a read-only solver:
//! it takes a dispute first and hands it to a person when needed, who takes
//! it over with a new `admin-took-dispute`. The app trusts the node it
//! already trusts, so a solver is shown as the assistant only when a known
//! node announces its key — never on the solver's own say-so.
//!
//! Two sources, the live one first:
//! - the active node's announcement from its capability fetch, kept here per
//!   node (`None` once a fetch saw no tag, which retracts a cached one);
//! - every registry node's kind 38385 cached by `node_stats`, so a dispute of
//!   a node the user switched away from keeps its label.
//!
//! Read at display time, not when a message arrives: a history replay can
//! land before the capability fetch, and the label then corrects itself.

use std::collections::HashMap;
use std::sync::RwLock;

use nostr_sdk::prelude::PublicKey;

/// The tag a node announces its Serbero in.
const SERBERO_TAG: &str = "serbero";

/// Per node (hex), what its last capability fetch announced.
static LIVE: RwLock<Option<HashMap<String, Option<String>>>> = RwLock::new(None);

/// The Serbero pubkey an info event's tags announce, as lowercase hex, or
/// `None` without the tag or with a value that is not a public key.
pub(crate) fn parse_tag(tags: &[Vec<String>]) -> Option<String> {
    let value = tags
        .iter()
        .find(|tag| tag.first().map(String::as_str) == Some(SERBERO_TAG))?
        .get(1)?
        .trim()
        .to_lowercase();
    is_pubkey(&value).then_some(value)
}

/// Record what `node`'s capability fetch announced: its Serbero, or none.
pub(crate) fn set_from_tags(node: &str, tags: &[Vec<String>]) {
    LIVE.write()
        .unwrap_or_else(|e| e.into_inner())
        .get_or_insert_with(HashMap::new)
        .insert(node.to_lowercase(), parse_tag(tags));
}

/// Whether `pubkey` is a Serbero some known node announces. `live` wins over
/// `cached` for a node it has an answer for.
fn is_assistant_in(
    pubkey: &str,
    live: &HashMap<String, Option<String>>,
    cached: &HashMap<String, Vec<Vec<String>>>,
) -> bool {
    let pubkey = pubkey.trim().to_lowercase();
    let announced_live = live.values().flatten().any(|serbero| *serbero == pubkey);
    announced_live
        || cached
            .iter()
            .filter(|(node, _)| !live.contains_key(&node.to_lowercase()))
            .any(|(_, tags)| parse_tag(tags).as_deref() == Some(pubkey.as_str()))
}

/// Whether the solver `pubkey` (hex) is a Serbero, by the live
/// announcements and the cached info events of every registry node.
pub(crate) async fn is_assistant(pubkey: &str) -> bool {
    let live = LIVE
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_default();
    let cached = crate::api::node_stats::cached_info_tags().await;
    is_assistant_in(pubkey, &live, &cached)
}

fn is_pubkey(hex: &str) -> bool {
    hex.len() == 64 && PublicKey::from_hex(hex).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SERBERO: &str = "000005ee0a1a2b3033d2908bb2fc7e29de803d5ac55a249cdebc11d50fca7fc0";
    const HUMAN: &str = "00000f13a1a2b3033d2908bb2fc7e29de803d5ac55a249cdebc11d50fca7fc00";
    const NODE: &str = "dbe0b1be7aafd3cfba92d7463edbd4e33b2969f61bd554d37ac56f032e13355a";
    const OTHER_NODE: &str = "82fa8cb978b43c79b2156585bac2c011176a21d2aead6d9f7c575c005be88390";

    fn tags(pairs: &[(&str, &str)]) -> Vec<Vec<String>> {
        pairs
            .iter()
            .map(|(k, v)| vec![k.to_string(), v.to_string()])
            .collect()
    }

    #[test]
    fn the_serbero_tag_is_read_as_lowercase_hex() {
        assert_eq!(
            parse_tag(&tags(&[("pow", "0"), ("serbero", SERBERO)])).as_deref(),
            Some(SERBERO)
        );
        assert_eq!(
            parse_tag(&tags(&[("serbero", &format!(" {} ", SERBERO.to_uppercase()))])).as_deref(),
            Some(SERBERO)
        );
    }

    #[test]
    fn a_missing_or_malformed_serbero_tag_announces_nobody() {
        assert_eq!(parse_tag(&tags(&[("pow", "0")])), None);
        assert_eq!(parse_tag(&tags(&[("serbero", "")])), None);
        assert_eq!(parse_tag(&tags(&[("serbero", "npub1notakey")])), None);
        assert_eq!(parse_tag(&tags(&[("serbero", &SERBERO[..63])])), None);
        assert_eq!(parse_tag(&[vec!["serbero".to_string()]]), None);
    }

    #[test]
    fn a_solver_is_the_assistant_only_when_a_known_node_announces_it() {
        // Arrange: another node's cached info event announces the Serbero.
        let live = HashMap::new();
        let cached = HashMap::from([
            (NODE.to_string(), tags(&[("pow", "0")])),
            (OTHER_NODE.to_string(), tags(&[("serbero", SERBERO)])),
        ]);

        // Act + Assert
        assert!(is_assistant_in(SERBERO, &live, &cached));
        assert!(is_assistant_in(&SERBERO.to_uppercase(), &live, &cached));
        assert!(!is_assistant_in(HUMAN, &live, &cached));
        assert!(!is_assistant_in(SERBERO, &live, &HashMap::new()));
    }

    #[test]
    fn a_live_fetch_without_the_tag_retracts_the_cached_announcement() {
        // Arrange: the cache still holds the node's older event with the tag;
        // its latest fetch no longer announces one (the operator removed it).
        let cached = HashMap::from([(NODE.to_string(), tags(&[("serbero", SERBERO)]))]);
        let retracted = HashMap::from([(NODE.to_string(), None)]);
        let announced = HashMap::from([(NODE.to_string(), Some(SERBERO.to_string()))]);

        // Act + Assert
        assert!(!is_assistant_in(SERBERO, &retracted, &cached));
        assert!(is_assistant_in(SERBERO, &announced, &HashMap::new()));
    }
}
