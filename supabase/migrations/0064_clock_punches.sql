-- 0064: marcaje de entrada y salida de los conductores (ubicación + foto) sobre la jornada (shifts).
-- Reutiliza shifts: la entrada abre la jornada y la salida la cierra. No se toca start_shift/end_shift salvo para
-- que, en las empresas con zonas configuradas, solo se pueda iniciar y cerrar por el marcaje.

-- ---------------------------------------------------------------- configuración por empresa
alter table public.companies
  add column clock_out_of_zone text not null default 'block' check (clock_out_of_zone in ('block', 'review')),
  add column clock_photo_days  integer not null default 30 check (clock_photo_days between 7 and 365);

create table public.clock_zones (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  name       text not null check (length(btrim(name)) between 1 and 80),
  lat        double precision not null check (lat between -90 and 90),
  lng        double precision not null check (lng between -180 and 180),
  radius_m   integer not null check (radius_m between 20 and 5000),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, name)
);
create index clock_zones_company_idx on public.clock_zones (company_id) where active;

-- ---------------------------------------------------------------- marcajes (registro original, no se modifica)
create table public.shift_punches (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies (id),
  driver_id     uuid not null references public.profiles (id),
  shift_id      uuid not null references public.shifts (id),
  kind          text not null check (kind in ('in', 'out')),
  server_at     timestamptz not null default now(),   -- hora oficial: reloj del servidor
  captured_at   timestamptz,                          -- hora del teléfono al capturar (solo informativa)
  lat           double precision not null,
  lng           double precision not null,
  accuracy_m    real,                                 -- precisión que informó el teléfono (evidencia, no prueba)
  zone_id       uuid references public.clock_zones (id) on delete set null,
  zone_name     text,                                 -- copia: sobrevive si la zona se borra o se renombra
  distance_m    integer,                              -- distancia al borde de la zona más cercana (0 si está dentro)
  inside        boolean not null,
  low_accuracy  boolean not null default false,
  delayed       boolean not null default false,       -- se envió con demora (sin conexión al marcar)
  photo_path    text not null,
  photo_purged_at timestamptz,                        -- la foto se borró por vencimiento; el marcaje queda
  client_key    uuid not null,                        -- evita duplicados por doble toque o reintento
  unique (driver_id, client_key),
  unique (shift_id, kind)
);
create index shift_punches_company_time_idx on public.shift_punches (company_id, server_at desc);
create index shift_punches_driver_time_idx  on public.shift_punches (company_id, driver_id, server_at desc);
create index shift_punches_review_idx       on public.shift_punches (company_id, server_at desc) where not inside or low_accuracy;

-- el original no se altera ni se borra; lo único que cambia es el aviso de que la foto venció
create function public._punch_immutable() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'IMMUTABLE: los marcajes no se pueden borrar'; end if;
  if (to_jsonb(new) - 'photo_purged_at') is distinct from (to_jsonb(old) - 'photo_purged_at') then
    raise exception 'IMMUTABLE: los marcajes no se pueden modificar';
  end if;
  return new;
end $$;
create trigger shift_punches_immutable before update or delete on public.shift_punches
  for each row execute function public._punch_immutable();

-- revisión del administrador: va aparte, el marcaje original queda intacto
create table public.punch_reviews (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id),
  punch_id    uuid not null references public.shift_punches (id),
  reviewer_id uuid not null references public.profiles (id),
  decision    text not null check (decision in ('approved', 'rejected')),
  note        text check (note is null or length(note) <= 500),
  created_at  timestamptz not null default now()
);
create index punch_reviews_punch_idx on public.punch_reviews (punch_id, created_at desc);

alter table public.clock_zones    enable row level security;
alter table public.shift_punches  enable row level security;
alter table public.punch_reviews  enable row level security;

create policy clock_zones_select on public.clock_zones for select to authenticated
  using (company_id = public.current_company_id());
create policy clock_zones_admin on public.clock_zones for all to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin())
  with check (company_id = public.current_company_id() and public.is_company_admin());

-- el conductor ve solo los suyos; el admin de la empresa ve los de su empresa; nadie cruza empresas
create policy shift_punches_select on public.shift_punches for select to authenticated
  using (company_id = public.current_company_id()
         and (public.is_company_admin() or driver_id = auth.uid()));
create policy punch_reviews_select on public.punch_reviews for select to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin());

-- ---------------------------------------------------------------- fotos: almacenamiento privado
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('punch-photos', 'punch-photos', false, 1572864, array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- ruta: <empresa>/<conductor>/<clave>-<in|out>.jpg ; el conductor solo sube en su carpeta
create policy punch_photos_driver_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'punch-photos'
    and public.current_user_role() = 'driver'
    and split_part(name, '/', 1) = public.current_company_id()::text
    and split_part(name, '/', 2) = auth.uid()::text
    and name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}-(in|out)\.jpg$'
  );
create policy punch_photos_select on storage.objects for select to authenticated
  using (
    bucket_id = 'punch-photos'
    and split_part(name, '/', 1) = public.current_company_id()::text
    and (public.is_company_admin() or split_part(name, '/', 2) = auth.uid()::text)
  );
-- sin políticas de update/delete: la limpieza por vencimiento la hace el servidor con su clave de servicio

-- ---------------------------------------------------------------- jornada: lógica única (la usan el marcaje y las funciones viejas)
create function public._shift_open() returns public.shifts
language plpgsql security definer set search_path = public as $$
declare v_row public.shifts;
begin
  select * into v_row from public.shifts where driver_id = auth.uid() and ended_at is null;
  if found then return v_row; end if;
  insert into public.shifts (company_id, driver_id) values (public.current_company_id(), auth.uid())
  returning * into v_row;
  return v_row;
end $$;

create function public._shift_close() returns public.shifts
language plpgsql security definer set search_path = public as $$
declare v_row public.shifts;
begin
  if exists (select 1 from public.trips where driver_id = auth.uid() and status = 'in_progress') then
    raise exception 'TRIP_IN_PROGRESS: finalice el viaje antes de cerrar la jornada';
  end if;
  update public.shifts set ended_at = now() where driver_id = auth.uid() and ended_at is null
  returning * into v_row;
  if not found then raise exception 'NO_OPEN_SHIFT'; end if;
  return v_row;
end $$;
revoke all on function public._shift_open(), public._shift_close() from public, anon, authenticated;

create function public._clock_required(p_company uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.clock_zones where company_id = p_company and active);
$$;
revoke all on function public._clock_required(uuid) from public, anon, authenticated;

-- las funciones de siempre siguen para las empresas sin zonas; con zonas, solo se entra y sale marcando
create or replace function public.start_shift() returns public.shifts
language plpgsql security definer set search_path = public as $$
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if public._clock_required(public.current_company_id()) then
    raise exception 'CLOCK_REQUIRED: iniciá la jornada con el marcaje de entrada (foto y ubicación)';
  end if;
  return public._shift_open();
end $$;

create or replace function public.end_shift() returns public.shifts
language plpgsql security definer set search_path = public as $$
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if public._clock_required(public.current_company_id()) then
    raise exception 'CLOCK_REQUIRED: cerrá la jornada con el marcaje de salida (foto y ubicación)';
  end if;
  return public._shift_close();
end $$;

-- ---------------------------------------------------------------- distancia (metros) entre dos puntos
create function public._distance_m(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371000 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))));
$$;

-- ---------------------------------------------------------------- marcar
create function public.punch_shift(
  p_kind text, p_client_key uuid, p_lat double precision, p_lng double precision,
  p_accuracy double precision, p_captured_at timestamptz
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_mode text;
  v_prev public.shift_punches;
  v_path text;
  v_zone public.clock_zones;
  v_zone_id uuid;
  v_excess double precision;
  v_inside boolean;
  v_low boolean;
  v_delayed boolean;
  v_shift public.shifts;
  v_punch public.shift_punches;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_kind not in ('in', 'out') then raise exception 'INVALID_KIND: tipo de marcaje inválido'; end if;
  if p_client_key is null then raise exception 'INVALID_KEY: falta la clave del marcaje'; end if;

  -- reintento o doble toque: devuelve el marcaje ya registrado
  select * into v_prev from public.shift_punches where driver_id = auth.uid() and client_key = p_client_key;
  if found then
    return jsonb_build_object('status', 'duplicate', 'id', v_prev.id, 'kind', v_prev.kind, 'server_at', v_prev.server_at,
                              'inside', v_prev.inside, 'zone_name', v_prev.zone_name);
  end if;

  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'INVALID_LOCATION: no se pudo leer la ubicación del teléfono';
  end if;
  if not public._clock_required(v_company) then
    raise exception 'CLOCK_NOT_CONFIGURED: tu empresa todavía no configuró una zona de marcaje';
  end if;

  v_path := v_company::text || '/' || auth.uid()::text || '/' || p_client_key::text || '-' || p_kind || '.jpg';
  if not exists (select 1 from storage.objects where bucket_id = 'punch-photos' and name = v_path) then
    raise exception 'PHOTO_MISSING: la foto no llegó al servidor, intentá de nuevo';
  end if;

  select clock_out_of_zone into v_mode from public.companies where id = v_company;

  -- zona más cercana al borde (si está dentro de alguna, esa)
  select z.id, public._distance_m(p_lat, p_lng, z.lat, z.lng) - z.radius_m
    into v_zone_id, v_excess
    from public.clock_zones z where z.company_id = v_company and z.active
    order by 2 limit 1;
  select * into v_zone from public.clock_zones where id = v_zone_id;
  v_inside := v_excess <= 0;
  v_low := p_accuracy is null or p_accuracy > 100;
  v_delayed := p_captured_at is not null and p_captured_at < now() - interval '2 minutes';

  if not v_inside and v_mode = 'block' then
    raise exception 'OUT_OF_ZONE: estás a % m de "%" (el máximo permitido es % m). Acercate al lugar para marcar.',
      round(v_excess + v_zone.radius_m)::int, v_zone.name, v_zone.radius_m;
  end if;

  if p_kind = 'in' then
    if exists (select 1 from public.shifts where driver_id = auth.uid() and ended_at is null) then
      raise exception 'ALREADY_IN: la jornada ya está iniciada';
    end if;
    v_shift := public._shift_open();
  else
    v_shift := public._shift_close();   -- falla con NO_OPEN_SHIFT o TRIP_IN_PROGRESS
  end if;

  insert into public.shift_punches (company_id, driver_id, shift_id, kind, captured_at, lat, lng, accuracy_m,
                                    zone_id, zone_name, distance_m, inside, low_accuracy, delayed, photo_path, client_key)
  values (v_company, auth.uid(), v_shift.id, p_kind,
          case when p_captured_at between now() - interval '3 days' and now() + interval '5 minutes' then p_captured_at end,
          p_lat, p_lng, p_accuracy, v_zone.id, v_zone.name, greatest(0, round(v_excess))::int, v_inside, v_low, v_delayed,
          v_path, p_client_key)
  returning * into v_punch;

  return jsonb_build_object('status', 'ok', 'id', v_punch.id, 'kind', v_punch.kind, 'server_at', v_punch.server_at,
                            'inside', v_inside, 'low_accuracy', v_low, 'zone_name', v_zone.name, 'shift_id', v_shift.id);
end $$;

-- ---------------------------------------------------------------- configuración y revisión (administrador de empresa)
create function public.save_clock_settings(p_mode text, p_photo_days integer) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_mode not in ('block', 'review') then raise exception 'INVALID_MODE: elegí bloquear o registrar para revisión'; end if;
  if p_photo_days not between 7 and 365 then raise exception 'INVALID_DAYS: los días de conservación van de 7 a 365'; end if;
  update public.companies set clock_out_of_zone = p_mode, clock_photo_days = p_photo_days where id = public.current_company_id();
end $$;

create function public.review_punch(p_punch uuid, p_decision text, p_note text) returns public.punch_reviews
language plpgsql security definer set search_path = public as $$
declare v_row public.punch_reviews;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception 'INVALID_DECISION: decisión inválida'; end if;
  if not exists (select 1 from public.shift_punches where id = p_punch and company_id = public.current_company_id()) then
    raise exception 'NOT_FOUND';
  end if;
  insert into public.punch_reviews (company_id, punch_id, reviewer_id, decision, note)
  values (public.current_company_id(), p_punch, auth.uid(), p_decision, nullif(btrim(p_note), ''))
  returning * into v_row;
  return v_row;
end $$;

revoke all on function public.punch_shift(text, uuid, double precision, double precision, double precision, timestamptz),
                       public.save_clock_settings(text, integer), public.review_punch(uuid, text, text) from public, anon;
grant execute on function public.punch_shift(text, uuid, double precision, double precision, double precision, timestamptz),
                          public.save_clock_settings(text, integer), public.review_punch(uuid, text, text) to authenticated;
