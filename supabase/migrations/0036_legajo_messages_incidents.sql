-- Legajo del personal, mensajes del panel GPS a los conductores y gestion de incidencias.

-- ---------------------------------------------------------------- legajo
alter table public.profiles add column if not exists legajo text;
alter table public.profiles drop constraint if exists profiles_legajo_check;
alter table public.profiles add constraint profiles_legajo_check check (legajo is null or length(trim(legajo)) between 1 and 20);
create unique index if not exists profiles_legajo_company_uq on public.profiles (company_id, lower(legajo))
  where legajo is not null and company_id is not null;
create unique index if not exists profiles_legajo_platform_uq on public.profiles (lower(legajo))
  where legajo is not null and company_id is null;

-- Cambiar el legajo de alguien ya cargado: el admin de la empresa (su personal) o el admin general.
create or replace function public.set_legajo(p_profile uuid, p_legajo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_target public.profiles;
begin
  select * into v_target from public.profiles where id = p_profile;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not (public.is_platform_admin()
          or (public.is_company_admin() and v_target.company_id = public.current_company_id())) then
    raise exception 'FORBIDDEN';
  end if;
  begin
    update public.profiles set legajo = nullif(trim(p_legajo), '') where id = p_profile;
  exception when unique_violation then
    raise exception 'LEGAJO_DUPLICATE: Ese legajo ya lo tiene otra persona.';
  end;
end $$;
revoke all on function public.set_legajo(uuid, text) from public, anon;
grant execute on function public.set_legajo(uuid, text) to authenticated;

-- ---------------------------------------------------------------- mensajes a conductores
create table if not exists public.driver_messages (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  trip_id    uuid references public.trips (id) on delete cascade,   -- null = para todos los conductores de la empresa
  level      text not null default 'info' check (level in ('info','important','urgent')),
  body       text not null check (length(trim(body)) between 1 and 500),
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now()
);
create index if not exists driver_messages_company_idx on public.driver_messages (company_id, created_at desc);
alter table public.driver_messages enable row level security;
revoke all on public.driver_messages from anon, authenticated;
grant select on public.driver_messages to authenticated;

create table if not exists public.driver_message_reads (
  message_id uuid not null references public.driver_messages (id) on delete cascade,
  driver_id  uuid not null references public.profiles (id),
  read_at    timestamptz not null default now(),
  primary key (message_id, driver_id)
);
alter table public.driver_message_reads enable row level security;
revoke all on public.driver_message_reads from anon, authenticated;
grant select on public.driver_message_reads to authenticated;

-- El conductor ve los de su empresa (para todos o para su viaje) de los ultimos 3 dias; el admin de empresa, todos los suyos.
drop policy if exists driver_messages_select on public.driver_messages;
create policy driver_messages_select on public.driver_messages for select to authenticated
  using (company_id = public.current_company_id() and (
    public.current_user_role() = 'company_admin'
    or (public.current_user_role() = 'driver' and created_at > now() - interval '3 days'
        and (trip_id is null or exists (select 1 from public.trips t where t.id = trip_id and t.driver_id = auth.uid())))
  ));
drop policy if exists driver_message_reads_select on public.driver_message_reads;
create policy driver_message_reads_select on public.driver_message_reads for select to authenticated
  using (driver_id = auth.uid()
         or (public.current_user_role() = 'company_admin'
             and exists (select 1 from public.driver_messages m where m.id = message_id and m.company_id = public.current_company_id())));

create or replace function public.send_driver_message(p_body text, p_level text default 'info', p_trip uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_id uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if not public.company_feature_enabled(v_company, 'gps') then
    raise exception 'FEATURE_BLOCKED: Esta empresa no tiene habilitado el seguimiento GPS.';
  end if;
  if p_level not in ('info','important','urgent') then raise exception 'LEVEL_INVALID'; end if;
  if p_body is null or length(trim(p_body)) = 0 then raise exception 'BODY_REQUIRED: Escribí el mensaje.'; end if;
  if p_trip is not null and not exists (select 1 from public.trips where id = p_trip and company_id = v_company) then
    raise exception 'NOT_FOUND';
  end if;
  insert into public.driver_messages (company_id, trip_id, level, body, created_by)
  values (v_company, p_trip, p_level, trim(p_body), auth.uid()) returning id into v_id;
  return v_id;
end $$;
revoke all on function public.send_driver_message(text, text, uuid) from public, anon;
grant execute on function public.send_driver_message(text, text, uuid) to authenticated;

create or replace function public.mark_messages_read(p_ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  insert into public.driver_message_reads (message_id, driver_id)
  select m.id, auth.uid() from public.driver_messages m
   where m.id = any (p_ids) and m.company_id = public.current_company_id()
     and (m.trip_id is null or exists (select 1 from public.trips t where t.id = m.trip_id and t.driver_id = auth.uid()))
  on conflict do nothing;
end $$;
revoke all on function public.mark_messages_read(uuid[]) from public, anon;
grant execute on function public.mark_messages_read(uuid[]) to authenticated;

-- ---------------------------------------------------------------- incidencias: emergencia y resuelta
alter table public.incidents drop constraint if exists incidents_kind_check;
alter table public.incidents add constraint incidents_kind_check
  check (kind in ('breakdown','delay','accident','traffic','other','panic'));
alter table public.incidents add column if not exists resolved_at timestamptz;
alter table public.incidents add column if not exists resolved_by uuid references public.profiles (id);

create or replace function public._report_incident_impl(p_trip uuid, p_kind text, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_kind not in ('breakdown','delay','accident','traffic','other','panic') then raise exception 'KIND_INVALID: tipo de incidencia invalido'; end if;
  if p_kind = 'other' and (p_note is null or length(trim(p_note)) < 3) then raise exception 'NOTE_REQUIRED: describa la incidencia'; end if;
  if not exists (select 1 from public.trips where id = p_trip and driver_id = auth.uid() and company_id = public.current_company_id()) then
    raise exception 'NOT_FOUND';
  end if;
  insert into public.incidents (company_id, trip_id, driver_id, kind, note)
  values (public.current_company_id(), p_trip, auth.uid(), p_kind, nullif(trim(p_note), ''))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.resolve_incident(p_incident uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  update public.incidents set resolved_at = now(), resolved_by = auth.uid()
   where id = p_incident and company_id = public.current_company_id() and resolved_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;
revoke all on function public.resolve_incident(uuid) from public, anon;
grant execute on function public.resolve_incident(uuid) to authenticated;
