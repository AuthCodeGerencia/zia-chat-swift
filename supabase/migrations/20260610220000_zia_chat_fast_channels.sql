create or replace function public.core_list_zia_channels()
returns table (
  id uuid,
  empresa_id integer,
  name text,
  slug text,
  description text,
  visibility text,
  is_archived boolean,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  metadata jsonb,
  conversation_id uuid,
  unread_count bigint,
  mention_count bigint,
  current_user_is_member boolean,
  visible_as_super_admin boolean
)
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
  )
  select
    c.id,
    c.empresa_id,
    c.name,
    c.slug,
    c.description,
    c.visibility::text,
    c.is_archived,
    c.created_by,
    c.created_at,
    c.updated_at,
    c.metadata,
    conv.id as conversation_id,
    0::bigint as unread_count,
    0::bigint as mention_count,
    member.user_id is not null as current_user_is_member,
    (
      me.is_super_admin
      and c.created_by is distinct from me.user_id
      and member.user_id is null
    ) as visible_as_super_admin
  from public.core_channels c
  cross join me
  left join public.core_conversations conv on conv.channel_id = c.id
  left join public.core_channel_members member
    on member.channel_id = c.id
   and member.user_id = me.user_id
  where c.empresa_id = me.empresa_id
    and c.is_archived = false
    and (
      me.is_super_admin
      or c.created_by = me.user_id
      or member.user_id is not null
    )
  order by c.slug asc
$$;

grant execute on function public.core_list_zia_channels() to authenticated;
