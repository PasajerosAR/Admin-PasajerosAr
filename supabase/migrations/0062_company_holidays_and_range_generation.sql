-- 0062: calendario de feriados por empresa + generar/publicar varios dias de una vez.
-- Los feriados los carga cada empresa (no el admin general). El tipo de dia de una fecha es
-- "feriado" si esta en el calendario de la empresa; si no, el que corresponde al dia de la semana.

create table public.company_holidays (
  company_id uuid not null references public.companies (id) on delete cascade,
  holiday_date date not null,
  name text not null check (length(trim(name)) between 1 and 80),
  created_at timestamptz not null default now(),
  primary key (company_id, holiday_date)
);
alter table public.company_holidays enable row level security;
create policy company_holidays_select on public.company_holidays for select to authenticated
  using (company_id = public.current_company_id() and public.current_user_role()::text in ('company_admin', 'seller', 'support'));
create policy company_holidays_insert on public.company_holidays for insert to authenticated
  with check (company_id = public.current_company_id() and public.is_company_admin());
create policy company_holidays_update on public.company_holidays for update to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin())
  with check (company_id = public.current_company_id() and public.is_company_admin());
create policy company_holidays_delete on public.company_holidays for delete to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin());
grant select, insert, update, delete on public.company_holidays to authenticated;

create or replace function public.company_day_type(p_company uuid, p_date date) returns text
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.company_holidays h where h.company_id = p_company and h.holiday_date = p_date)
              then 'holiday' else public.day_type_of(p_date) end $$;
revoke all on function public.company_day_type(uuid, date) from public, anon, authenticated;

-- Un dia: genera los viajes y, si habia de otro tipo, los reemplaza cuando se confirmo (p_replace).
-- Devuelve el estado en vez de fallar, asi el mismo codigo sirve para un dia y para un rango.
create or replace function public._generate_day(p_company uuid, p_date date, p_type text, p_replace boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_other int; v_blocked int; v_created int; v_replaced int := 0;
begin
  select count(*), count(*) filter (where not replaceable) into v_other, v_blocked
    from public._trips_other_type(p_date, p_type, p_company);
  if v_other > 0 then
    if v_blocked > 0 then return jsonb_build_object('status', 'blocked', 'other_type', v_other, 'blocked', v_blocked, 'created', 0); end if;
    if not p_replace then return jsonb_build_object('status', 'replace_required', 'other_type', v_other, 'blocked', 0, 'created', 0); end if;
    delete from public.trips where id in (select id from public._trips_other_type(p_date, p_type, p_company));
    v_replaced := v_other;
  end if;
  -- los viajes generados quedan como borrador (published_at null) hasta que se publican
  insert into public.trips (company_id, service_id, departure_id, service_date, scheduled_departure, day_type, published_at)
  select d.company_id, d.service_id, d.id, p_date, public.departure_ts(p_date, d.departure_time, d.next_day), p_type, null
  from public.service_departures d
  join public.services s on s.id = d.service_id
  where d.company_id = p_company and s.active and d.active and p_type = any (d.day_types)
  on conflict (departure_id, service_date) do nothing;
  get diagnostics v_created = row_count;
  return jsonb_build_object('status', 'ok', 'other_type', v_other, 'blocked', 0, 'created', v_created, 'replaced', v_replaced);
end $$;
revoke all on function public._generate_day(uuid, date, text, boolean) from public, anon, authenticated;

create or replace function public.generate_trips(p_date date, p_day_type text default null, p_replace boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_type text := coalesce(p_day_type, public.company_day_type(public.current_company_id(), p_date));
  r jsonb;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if v_type not in ('weekday','saturday','sunday','holiday') then raise exception 'DAY_TYPE_INVALID: tipo de dia invalido'; end if;
  r := public._generate_day(v_company, p_date, v_type, p_replace);
  if r->>'status' = 'blocked' then
    raise exception 'TRIPS_BLOCKED: hay % viajes de otro tipo de dia con ventas, conductor o ya iniciados; no se pueden reemplazar', r->>'blocked';
  elsif r->>'status' = 'replace_required' then
    raise exception 'REPLACE_REQUIRED: el dia ya tiene % viajes de otro tipo de dia', r->>'other_type';
  end if;
  return (r->>'created')::int;
end $$;
grant execute on function public.generate_trips(date, text, boolean) to authenticated;

create or replace function public.generate_trips_preview(p_date date, p_day_type text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_type text := coalesce(p_day_type, public.company_day_type(public.current_company_id(), p_date));
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  return jsonb_build_object(
    'other_type', (select count(*) from public._trips_other_type(p_date, v_type, public.current_company_id())),
    'blocked', (select count(*) from public._trips_other_type(p_date, v_type, public.current_company_id()) where not replaceable),
    'types', coalesce((select jsonb_agg(distinct day_type) from public._trips_other_type(p_date, v_type, public.current_company_id())), '[]'::jsonb));
end $$;

-- Fechas de un rango con su tipo automatico (feriado si esta en el calendario de la empresa).
create or replace function public.day_types_for_range(p_from date, p_days int) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_days < 1 or p_days > 60 then raise exception 'RANGE_INVALID: se pueden generar entre 1 y 60 dias'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('date', x::date, 'day_type', public.company_day_type(public.current_company_id(), x::date),
                      'holiday', (select h.name from public.company_holidays h where h.company_id = public.current_company_id() and h.holiday_date = x::date)) order by x)
                     from generate_series(p_from, p_from + (p_days - 1), interval '1 day') x), '[]'::jsonb);
end $$;
grant execute on function public.day_types_for_range(date, int) to authenticated;

-- Conflictos por fecha (viajes de otro tipo) para mostrar antes de generar.
create or replace function public.generate_trips_range_preview(p_dates date[], p_types text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if coalesce(array_length(p_dates, 1), 0) <> coalesce(array_length(p_types, 1), 0) or coalesce(array_length(p_dates, 1), 0) > 60 then
    raise exception 'RANGE_INVALID: rango invalido';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('date', p_dates[i], 'day_type', p_types[i],
      'other_type', (select count(*) from public._trips_other_type(p_dates[i], p_types[i], public.current_company_id())),
      'blocked', (select count(*) from public._trips_other_type(p_dates[i], p_types[i], public.current_company_id()) where not replaceable)) order by i)
    from generate_series(1, coalesce(array_length(p_dates, 1), 0)) i), '[]'::jsonb);
end $$;
grant execute on function public.generate_trips_range_preview(date[], text[]) to authenticated;

-- Varios dias: cada fecha con su tipo. Las que no se pueden reemplazar se saltean y se informan.
create or replace function public.generate_trips_range(p_dates date[], p_types text[], p_replace boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_out jsonb := '[]'::jsonb;
  i int; r jsonb;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if coalesce(array_length(p_dates, 1), 0) < 1 or array_length(p_dates, 1) > 60 or array_length(p_dates, 1) <> coalesce(array_length(p_types, 1), 0) then
    raise exception 'RANGE_INVALID: se pueden generar entre 1 y 60 dias';
  end if;
  for i in 1 .. array_length(p_dates, 1) loop
    if p_types[i] not in ('weekday','saturday','sunday','holiday') then raise exception 'DAY_TYPE_INVALID: tipo de dia invalido'; end if;
    r := public._generate_day(v_company, p_dates[i], p_types[i], p_replace);
    v_out := v_out || jsonb_build_array(r || jsonb_build_object('date', p_dates[i], 'day_type', p_types[i]));
  end loop;
  return v_out;
end $$;
grant execute on function public.generate_trips_range(date[], text[], boolean) to authenticated;

create or replace function public.publish_trips_range(p_from date, p_to date) returns integer
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_to < p_from or p_to - p_from > 60 then raise exception 'RANGE_INVALID: rango invalido'; end if;
  update public.trips set published_at = now()
   where company_id = public.current_company_id() and service_date between p_from and p_to
     and published_at is null and status = 'scheduled';
  get diagnostics v_n = row_count;
  return v_n;
end $$;
grant execute on function public.publish_trips_range(date, date) to authenticated;
