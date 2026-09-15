// Unit tests for web/push_worker_logic.js, the decisions the messaging
// service worker makes (docs/PUSH_NOTIFICATIONS.md §2.6, T4.5).
//
// Usage:  node --test test/web/push_worker/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { notificationTarget, noticeFor, CHAT_WAKE_BODIES } = require('../../../web/push_worker_logic.js');

const WORKER = 'https://mostro.network/app/firebase-messaging-sw.js';

test('a tap opens Notifications under the deployed base path', () => {
  assert.equal(notificationTarget(WORKER), 'https://mostro.network/app/#/notifications');
});

test('a tap at the root deployment opens Notifications at the root', () => {
  assert.equal(
    notificationTarget('http://127.0.0.1:8080/firebase-messaging-sw.js'),
    'http://127.0.0.1:8080/#/notifications',
  );
});

test('the target never depends on the payload — there is nothing to route on', () => {
  // notificationTarget takes no payload at all: a field the server never
  // sends cannot become a route.
  assert.equal(notificationTarget.length, 1);
});

test('a visible trade update is left to the SDK, which renders its block', () => {
  const payload = {
    notification: { title: 'Mostro', body: 'You have an update on your trade' },
    data: { type: 'trade_update' },
  };
  assert.equal(noticeFor(payload, ['en-US']), null);
});

test('a chat wake renders a content-free notice of its own', () => {
  const payload = { data: { type: 'chat_wake', source: 'mostro-push-server' } };
  assert.deepEqual(noticeFor(payload, ['en-US']), {
    title: 'Mostro',
    body: 'You have a new message',
  });
});

test('the chat-wake notice follows the browser language', () => {
  const payload = { data: { type: 'chat_wake' } };
  assert.equal(noticeFor(payload, ['es-AR', 'en']).body, 'Tienes un mensaje nuevo');
  assert.equal(noticeFor(payload, ['fr-CA']).body, 'Vous avez un nouveau message');
  assert.equal(noticeFor(payload, ['pt-BR', 'de-DE']).body, 'Du hast eine neue Nachricht');
});

test('a language the app does not ship falls back to English', () => {
  const payload = { data: { type: 'chat_wake' } };
  assert.equal(noticeFor(payload, ['ja-JP']).body, 'You have a new message');
  assert.equal(noticeFor(payload, []).body, 'You have a new message');
});

test('a payload naming an order still yields the same content-free notice', () => {
  const payload = { data: { type: 'chat_wake', orderId: 'abc', disputeId: 'def' } };
  const notice = noticeFor(payload, ['en']);
  assert.ok(!JSON.stringify(notice).includes('abc'));
  assert.ok(!JSON.stringify(notice).includes('def'));
});

test('an unknown data-only push renders nothing', () => {
  assert.equal(noticeFor({ data: { type: 'something_else' } }, ['en']), null);
  assert.equal(noticeFor({}, ['en']), null);
});

test('the notice ships the five app languages', () => {
  assert.deepEqual(Object.keys(CHAT_WAKE_BODIES).sort(), ['de', 'en', 'es', 'fr', 'it']);
});
