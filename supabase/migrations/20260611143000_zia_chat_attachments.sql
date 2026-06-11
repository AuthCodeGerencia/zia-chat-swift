create table if not exists public.core_attachments (
  id uuid primary key default gen_random_uuid(),
  empresa_id integer not null references public.internal_companies(id) on delete cascade,
  message_id uuid references public.core_messages(id) on delete cascade,
  ticket_id uuid,
  uploader_id uuid not null references public.profiles(id) on delete cascade,
  bucket text not null default 'core-attachments',
  path text not null,
  url text,
  file_name text not null,
  mime_type text,
  size_bytes bigint not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists core_attachments_message_id_idx
on public.core_attachments (message_id);

alter table public.core_attachments enable row level security;

drop policy if exists core_attachments_company_select on public.core_attachments;
create policy core_attachments_company_select
on public.core_attachments for select
using (empresa_id = public.core_user_company_id());

drop policy if exists core_attachments_company_insert on public.core_attachments;
create policy core_attachments_company_insert
on public.core_attachments for insert
with check (
  empresa_id = public.core_user_company_id()
  and uploader_id = auth.uid()
);

insert into storage.buckets (id, name, public)
values ('core-attachments', 'core-attachments', false)
on conflict (id) do nothing;

drop policy if exists "Authenticated read core attachments" on storage.objects;
create policy "Authenticated read core attachments"
on storage.objects for select
using (
  bucket_id = 'core-attachments'
  and auth.role() = 'authenticated'
);

drop policy if exists "Authenticated upload core attachments" on storage.objects;
create policy "Authenticated upload core attachments"
on storage.objects for insert
with check (
  bucket_id = 'core-attachments'
  and auth.role() = 'authenticated'
);
