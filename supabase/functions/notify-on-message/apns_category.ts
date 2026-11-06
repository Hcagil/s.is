// Picks the APNs category of a message push;
// a chat that ever held a locked message gets the locked category for every message,
// because its action token carries mark_read only.

export function apnsCategory(encrypted: boolean, chatEncrypted: boolean): string {
  return encrypted || chatEncrypted ? 'SIS_MESSAGE_LOCKED' : 'SIS_MESSAGE';
}
