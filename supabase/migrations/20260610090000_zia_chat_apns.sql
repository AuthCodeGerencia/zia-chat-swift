create extension if not exists pg_net with schema extensions;

create or replace function public.notify_zia_chat_apns()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  webhook_url text;
  webhook_secret text;
begin
  if new.deleted_at is not null then
    return new;
  end if;

  select decrypted_secret
    into webhook_url
  from vault.decrypted_secrets
  where name = 'zia_chat_push_webhook_url'
  limit 1;

  select decrypted_secret
    into webhook_secret
  from vault.decrypted_secrets
  where name = 'zia_chat_push_webhook_secret'
  limit 1;

  if webhook_url is null or webhook_secret is null then
    return new;
  end if;

  perform net.http_post(
    url := webhook_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-zia-chat-secret', webhook_secret
    ),
    body := jsonb_build_object('messageId', new.id::text)
  );

  return new;
end;
$$;

drop trigger if exists core_messages_zia_chat_apns on public.core_messages;
create trigger core_messages_zia_chat_apns
after insert on public.core_messages
for each row
execute function public.notify_zia_chat_apns();
