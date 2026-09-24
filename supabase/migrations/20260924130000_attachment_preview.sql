-- v0.9: a tiny preview travels with each photo message.
--
-- A receiver sees a blurred preview at once, from the message row itself,
-- while the full photo downloads. It is a few-hundred-byte PNG made on the
-- sender's phone (about 24 px wide), readable exactly where the message is:
-- the row's existing policies cover it, nothing new is exposed.
alter table public.messages add column attachment_preview text;

-- Only well-formed base64 of a PNG, only on a photo message. Messages cannot
-- be edited, so a malformed preview would stay in a conversation for good;
-- the database refuses it rather than trusting every client to.
alter table public.messages
  add constraint messages_attachment_preview_check
  check (attachment_preview is null or (
    attachment_path is not null
    and char_length(attachment_preview) <= 4000
    and char_length(attachment_preview) % 4 = 0
    and attachment_preview ~ '^[A-Za-z0-9+/]+={0,2}$'
    -- base64 of the PNG signature
    and attachment_preview like 'iVBORw0KGgo%'));

-- Joins the column-level insert grant, like attachment_path did.
grant insert (attachment_preview) on public.messages to authenticated;
