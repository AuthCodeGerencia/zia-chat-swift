create index if not exists core_messages_zia_conversation_created_idx
on public.core_messages (conversation_id, created_at desc)
where deleted_at is null and parent_message_id is null;

do $$
begin
  if to_regclass('public.core_reactions') is not null then
    execute 'create index if not exists core_reactions_message_id_idx
      on public.core_reactions (message_id)';
  end if;

  if to_regclass('public.core_attachments') is not null then
    execute 'create index if not exists core_attachments_message_id_idx
      on public.core_attachments (message_id)';
  end if;
end
$$;

create or replace function public.core_list_zia_messages(
  p_conversation_id uuid,
  p_limit integer default 21
)
returns setof public.core_messages
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select
      p.id as user_id,
      p.empresa_id,
      (p.rol_id = 1 and p.client_id is null) as is_super_admin
    from public.profiles p
    where p.id = auth.uid()
    limit 1
  ),
  allowed as (
    select conv.id
    from public.core_conversations conv
    join public.core_channels c on c.id = conv.channel_id
    cross join me
    left join public.core_channel_members member
      on member.channel_id = c.id
     and member.user_id = me.user_id
    where conv.id = p_conversation_id
      and c.empresa_id = me.empresa_id
      and c.is_archived = false
      and (
        me.is_super_admin
        or c.created_by = me.user_id
        or member.user_id is not null
      )
    limit 1
  )
  select message.*
  from public.core_messages message
  join allowed on allowed.id = message.conversation_id
  where message.deleted_at is null
    and message.parent_message_id is null
  order by message.created_at desc
  limit least(greatest(coalesce(p_limit, 21), 1), 100)
$$;

revoke all on function public.core_list_zia_messages(uuid, integer) from public;
grant execute on function public.core_list_zia_messages(uuid, integer) to authenticated;
