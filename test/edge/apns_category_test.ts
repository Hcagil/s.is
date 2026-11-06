// apnsCategory: the locked category whenever the message or its chat ever held a locked message.
import { assertEquals } from 'jsr:@std/assert@1';
import { apnsCategory } from '../../supabase/functions/notify-on-message/apns_category.ts';

for (
  const [enc, chat, want] of [
    [false, false, 'SIS_MESSAGE'],
    [true, false, 'SIS_MESSAGE_LOCKED'],
    [false, true, 'SIS_MESSAGE_LOCKED'],
    [true, true, 'SIS_MESSAGE_LOCKED'],
  ] as const
) {
  Deno.test(`apnsCategory(encrypted=${enc}, chatEncrypted=${chat}) is ${want}`, () => {
    assertEquals(apnsCategory(enc, chat), want);
  });
}
