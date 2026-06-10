create table if not exists public.core_push_tokens (
  id uuid primary key default gen_random_uuid(),
  empresa_id integer not null references public.internal_companies(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  platform text not null,
  token text not null unique,
  device_name text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists core_push_tokens_user_platform_idx
  on public.core_push_tokens (user_id, platform);

alter table public.core_push_tokens enable row level security;

drop policy if exists core_push_tokens_user_select on public.core_push_tokens;
create policy core_push_tokens_user_select
  on public.core_push_tokens
  for select
  using (
    user_id = auth.uid()
    and empresa_id = public.core_user_company_id()
  );

drop policy if exists core_push_tokens_user_insert on public.core_push_tokens;
create policy core_push_tokens_user_insert
  on public.core_push_tokens
  for insert
  with check (
    user_id = auth.uid()
    and empresa_id = public.core_user_company_id()
    and platform = 'zia_chat_apns'
  );

drop policy if exists core_push_tokens_user_update on public.core_push_tokens;
create policy core_push_tokens_user_update
  on public.core_push_tokens
  for update
  using (
    user_id = auth.uid()
    and empresa_id = public.core_user_company_id()
  )
  with check (
    user_id = auth.uid()
    and empresa_id = public.core_user_company_id()
    and platform = 'zia_chat_apns'
  );

drop policy if exists core_push_tokens_user_delete on public.core_push_tokens;
create policy core_push_tokens_user_delete
  on public.core_push_tokens
  for delete
  using (
    user_id = auth.uid()
    and empresa_id = public.core_user_company_id()
  );
