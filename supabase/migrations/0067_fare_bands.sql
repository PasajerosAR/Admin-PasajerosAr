-- 0067: franjas horarias de precio.
-- Cada empresa define sus franjas (nombre y color), pinta una semana base (7 días × 24 horas) y puede cargar excepciones por fecha.
-- La franja de un viaje se resuelve UNA vez, con la hora de salida, y se guarda en el viaje (trips.fare_band): un cambio posterior
-- en las franjas no altera viajes ya generados ni pasajes vendidos.
--  * El tipo de día (hábil, sábado, domingo, feriado) sigue decidiendo QUÉ HORARIOS corren ese día.
--  * La franja decide CUÁNTO SE COBRA: las tarifas (ticket_prices.day_type) y los abonos (day_types) guardan el código de la franja.
--  * Cada empresa arranca con cuatro franjas (weekday, saturday, sunday, holiday) y una semana base igual al comportamiento anterior,
--    así que sus tarifas y abonos actuales siguen valiendo sin tocar nada.

-- ---------------------------------------------------------------- tablas
create table public.fare_bands (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  code       text not null check (code ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name       text not null check (length(btrim(name)) between 1 and 40),
  color      text not null default '#0f5b8a' check (color ~ '^#[0-9a-fA-F]{6}$'),
  is_default boolean not null default false,
  sort       integer not null default 100,
  created_at timestamptz not null default now(),
  unique (company_id, code)
);
create unique index fare_bands_name_unique on public.fare_bands (company_id, lower(btrim(name)));

-- semana base: una celda por día (1 = lunes ... 7 = domingo) y hora de salida (0 a 23)
create table public.fare_band_weekly (
  company_id uuid not null references public.companies (id),
  dow        smallint not null check (dow between 1 and 7),
  hour       smallint not null check (hour between 0 and 23),
  band_id    uuid not null references public.fare_bands (id),
  primary key (company_id, dow, hour)
);

-- excepciones por fecha (feriados, puentes): pisan la semana base en ese rango de horas
create table public.fare_band_exceptions (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  on_date    date not null,
  from_hour  smallint not null check (from_hour between 0 and 23),
  to_hour    smallint not null check (to_hour between 1 and 24),
  band_id    uuid not null references public.fare_bands (id),
  created_at timestamptz not null default now(),
  check (from_hour < to_hour)
);
create index fare_band_exceptions_date_idx on public.fare_band_exceptions (company_id, on_date);

create function public._fare_exception_no_overlap() returns trigger
language plpgsql as $$
begin
  if exists (select 1 from public.fare_band_exceptions e
              where e.company_id = new.company_id and e.on_date = new.on_date and e.id <> new.id
                and e.from_hour < new.to_hour and new.from_hour < e.to_hour) then
    raise exception 'EXCEPTION_OVERLAP: ese día ya tiene una excepción que se superpone con esas horas';
  end if;
  return new;
end $$;
create trigger fare_exception_no_overlap before insert or update on public.fare_band_exceptions
  for each row execute function public._fare_exception_no_overlap();

alter table public.fare_bands            enable row level security;
alter table public.fare_band_weekly      enable row level security;
alter table public.fare_band_exceptions  enable row level security;
create policy fare_bands_select on public.fare_bands for select to authenticated using (company_id = public.current_company_id());
create policy fare_band_weekly_select on public.fare_band_weekly for select to authenticated using (company_id = public.current_company_id());
create policy fare_band_exceptions_select on public.fare_band_exceptions for select to authenticated using (company_id = public.current_company_id());
-- los pasajeros también ven los nombres de las franjas de las empresas (para mostrar para qué días vale un abono)
create policy fare_bands_public on public.fare_bands for select to anon, authenticated using (true);

-- ---------------------------------------------------------------- franjas iniciales de cada empresa
create function public._seed_fare_bands(p_company uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.fare_bands (company_id, code, name, is_default, sort, color) values
    (p_company, 'weekday',  'Día hábil', true, 1, '#0f5b8a'),
    (p_company, 'saturday', 'Sábado',    true, 2, '#b45309'),
    (p_company, 'sunday',   'Domingo',   true, 3, '#7c3aed'),
    (p_company, 'holiday',  'Feriado',   true, 4, '#b91c1c')
  on conflict (company_id, code) do nothing;
  insert into public.fare_band_weekly (company_id, dow, hour, band_id)
  select p_company, d, h,
         (select id from public.fare_bands where company_id = p_company and code = case when d = 6 then 'saturday' when d = 7 then 'sunday' else 'weekday' end)
    from generate_series(1, 7) d, generate_series(0, 23) h
  on conflict do nothing;
end $$;
revoke all on function public._seed_fare_bands(uuid) from public, anon, authenticated;

select public._seed_fare_bands(id) from public.companies;

create function public._companies_seed_fare_bands() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public._seed_fare_bands(new.id);
  return new;
end $$;
create trigger companies_seed_fare_bands after insert on public.companies
  for each row execute function public._companies_seed_fare_bands();

-- ---------------------------------------------------------------- qué franja le toca a una salida
-- 1) excepción de esa fecha y hora  2) tipo de día elegido a mano distinto del que corresponde a la fecha (ej. un lunes que se
-- trabaja como feriado: usa la franja de ese tipo)  3) semana base según día y hora de salida (hora de Argentina).
create function public.fare_band_for(p_company uuid, p_ts timestamptz, p_service_date date default null, p_day_type text default null)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_local timestamp := p_ts at time zone 'America/Argentina/Buenos_Aires';
  v_date date := v_local::date;
  v_hour int := extract(hour from v_local)::int;
  v_code text;
begin
  select b.code into v_code
    from public.fare_band_exceptions e join public.fare_bands b on b.id = e.band_id
   where e.company_id = p_company and e.on_date = v_date and v_hour >= e.from_hour and v_hour < e.to_hour limit 1;
  if v_code is not null then return v_code; end if;

  if p_day_type is not null and p_service_date is not null and p_day_type <> public.day_type_of(p_service_date)
     and exists (select 1 from public.fare_bands where company_id = p_company and code = p_day_type) then
    return p_day_type;
  end if;

  select b.code into v_code
    from public.fare_band_weekly w join public.fare_bands b on b.id = w.band_id
   where w.company_id = p_company and w.dow = extract(isodow from v_date)::int and w.hour = v_hour;
  return coalesce(v_code, p_day_type, 'weekday');
end $$;
revoke all on function public.fare_band_for(uuid, timestamptz, date, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- cada viaje guarda su franja
alter table public.trips add column fare_band text;
update public.trips set fare_band = day_type;     -- lo ya generado conserva el precio que tenía
alter table public.trips alter column fare_band set not null;

create function public._trip_fare_band() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.fare_band is null then
      new.fare_band := public.fare_band_for(new.company_id, new.scheduled_departure, new.service_date, new.day_type);
    end if;
  elsif (new.day_type is distinct from old.day_type or new.scheduled_departure is distinct from old.scheduled_departure)
        and not exists (select 1 from public.sale_tickets where trip_id = new.id)
        and not exists (select 1 from public.tickets where trip_id = new.id) then
    new.fare_band := public.fare_band_for(new.company_id, new.scheduled_departure, new.service_date, new.day_type);
  end if;
  return new;
end $$;
-- el nombre empieza con "a" para correr antes que otros disparadores que miren el viaje
create trigger a_trip_fare_band before insert or update of day_type, scheduled_departure on public.trips
  for each row execute function public._trip_fare_band();

-- ---------------------------------------------------------------- tarifas y abonos guardan el código de la franja
alter table public.ticket_prices drop constraint ticket_prices_day_type_check;
alter table public.pass_products drop constraint pass_products_day_types_check;
alter table public.passes drop constraint passes_day_types_check;
alter table public.pass_checkout_orders drop constraint pass_checkout_orders_day_types_check;
alter table public.pass_products add constraint pass_products_day_types_check check (cardinality(day_types) > 0);
alter table public.passes add constraint passes_day_types_check check (cardinality(day_types) > 0);
alter table public.pass_checkout_orders add constraint pass_checkout_orders_day_types_check check (cardinality(day_types) > 0);

create function public._pass_product_bands_valid() returns trigger
language plpgsql as $$
begin
  if exists (select 1 from unnest(new.day_types) c where not exists
             (select 1 from public.fare_bands b where b.company_id = new.company_id and b.code = c)) then
    raise exception 'PASS_INVALID: una de las franjas elegidas no existe en la empresa';
  end if;
  return new;
end $$;
create trigger pass_products_bands_valid before insert or update of day_types on public.pass_products
  for each row execute function public._pass_product_bands_valid();

-- ---------------------------------------------------------------- administración de franjas (administrador de empresa)
create function public._fare_slug(p_name text, p_company uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_base text; v_code text; v_n int := 1;
begin
  v_base := regexp_replace(translate(lower(btrim(p_name)), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', '-', 'g');
  v_base := btrim(v_base, '-');
  if v_base = '' then v_base := 'franja'; end if;
  v_code := v_base;
  while exists (select 1 from public.fare_bands where company_id = p_company and code = v_code) loop
    v_n := v_n + 1; v_code := v_base || '-' || v_n;
  end loop;
  return v_code;
end $$;
revoke all on function public._fare_slug(text, uuid) from public, anon, authenticated;

create function public.save_fare_band(p_id uuid, p_name text, p_color text) returns public.fare_bands
language plpgsql security definer set search_path = public as $$
declare v_row public.fare_bands; v_company uuid := public.current_company_id();
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if length(btrim(coalesce(p_name, ''))) < 1 or length(btrim(p_name)) > 40 then raise exception 'BAND_INVALID: poné un nombre de hasta 40 letras'; end if;
  if exists (select 1 from public.fare_bands where company_id = v_company and lower(btrim(name)) = lower(btrim(p_name)) and id is distinct from p_id) then
    raise exception 'BAND_DUPLICATE: ya hay una franja con ese nombre';
  end if;
  if p_id is null then
    insert into public.fare_bands (company_id, code, name, color, sort)
    values (v_company, public._fare_slug(p_name, v_company), btrim(p_name), coalesce(p_color, '#0f5b8a'),
            coalesce((select max(sort) from public.fare_bands where company_id = v_company), 0) + 1)
    returning * into v_row;
  else
    update public.fare_bands set name = btrim(p_name), color = coalesce(p_color, color)
     where id = p_id and company_id = v_company returning * into v_row;
    if not found then raise exception 'NOT_FOUND'; end if;
  end if;
  return v_row;
end $$;

create function public.delete_fare_band(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_band public.fare_bands; v_company uuid := public.current_company_id();
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  select * into v_band from public.fare_bands where id = p_id and company_id = v_company;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_band.is_default then raise exception 'BAND_IN_USE: las franjas iniciales no se pueden quitar, solo renombrar'; end if;
  if exists (select 1 from public.fare_band_weekly where band_id = p_id)
     or exists (select 1 from public.fare_band_exceptions where band_id = p_id)
     or exists (select 1 from public.ticket_prices where company_id = v_company and day_type = v_band.code)
     or exists (select 1 from public.pass_products where company_id = v_company and v_band.code = any (day_types))
     or exists (select 1 from public.passes where company_id = v_company and v_band.code = any (day_types))
     or exists (select 1 from public.trips where company_id = v_company and fare_band = v_band.code) then
    raise exception 'BAND_IN_USE: la franja se usa en la semana base, excepciones, tarifas, abonos o viajes; sacala de ahí primero';
  end if;
  delete from public.fare_bands where id = p_id;
end $$;

-- semana base completa: arreglo de 7 arreglos (lunes a domingo) de 24 códigos de franja
create function public.save_fare_week(p_grid jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid := public.current_company_id(); d int; h int; v_code text; v_id uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_grid) <> 'array' or jsonb_array_length(p_grid) <> 7 then raise exception 'GRID_INVALID: la semana tiene que tener 7 días'; end if;
  for d in 1..7 loop
    if jsonb_typeof(p_grid -> (d - 1)) <> 'array' or jsonb_array_length(p_grid -> (d - 1)) <> 24 then
      raise exception 'GRID_INVALID: cada día tiene que tener 24 horas';
    end if;
    for h in 0..23 loop
      v_code := p_grid -> (d - 1) ->> h;
      select id into v_id from public.fare_bands where company_id = v_company and code = v_code;
      if v_id is null then raise exception 'GRID_INVALID: franja inexistente (%)', v_code; end if;
      insert into public.fare_band_weekly (company_id, dow, hour, band_id) values (v_company, d, h, v_id)
      on conflict (company_id, dow, hour) do update set band_id = excluded.band_id;
    end loop;
  end loop;
end $$;

create function public.save_fare_exception(p_date date, p_from_hour int, p_to_hour int, p_band uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := public.current_company_id(); v_id uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_date is null or p_from_hour is null or p_to_hour is null or p_from_hour < 0 or p_to_hour > 24 or p_from_hour >= p_to_hour then
    raise exception 'EXCEPTION_INVALID: revisá la fecha y el rango de horas';
  end if;
  if not exists (select 1 from public.fare_bands where id = p_band and company_id = v_company) then raise exception 'NOT_FOUND'; end if;
  insert into public.fare_band_exceptions (company_id, on_date, from_hour, to_hour, band_id)
  values (v_company, p_date, p_from_hour, p_to_hour, p_band) returning id into v_id;
  return v_id;
end $$;

create function public.delete_fare_exception(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  delete from public.fare_band_exceptions where id = p_id and company_id = public.current_company_id();
end $$;

revoke all on function public.save_fare_band(uuid, text, text), public.delete_fare_band(uuid), public.save_fare_week(jsonb),
  public.save_fare_exception(date, int, int, uuid), public.delete_fare_exception(uuid) from public, anon;
grant execute on function public.save_fare_band(uuid, text, text), public.delete_fare_band(uuid), public.save_fare_week(jsonb),
  public.save_fare_exception(date, int, int, uuid), public.delete_fare_exception(uuid) to authenticated;

-- ---------------------------------------------------------------- precios, ventas y abonos leen la franja del viaje (trips.fare_band)

CREATE OR REPLACE FUNCTION public._begin_passenger_checkout_impl(p_user uuid, p_trip uuid, p_from_stop uuid, p_to_stop uuid, p_tickets jsonb, p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_trip public.trips;
  v_passenger public.passenger_profiles;
  v_company_id uuid;
  v_route_id uuid;
  v_route_name text;
  v_service_code text;
  v_from_pos int;
  v_to_pos int;
  v_input jsonb;
  v_items jsonb := '[]'::jsonb;
  v_first jsonb;
  v_cell_id uuid;
  v_seat_label text;
  v_seat_class text;
  v_passenger_name text;
  v_passenger_dni text;
  v_passenger_email text;
  v_price numeric(10, 2);
  v_total numeric(10, 2) := 0;
  v_order_id uuid;
  v_expires_at timestamptz;
  v_from_name text;
  v_to_name text;
  v_index int := 0;
begin
  if auth.role() <> 'service_role' then raise exception 'FORBIDDEN'; end if;
  if p_user is null or p_trip is null or p_from_stop is null or p_to_stop is null
     or p_tickets is null
     or length(trim(coalesce(p_phone, ''))) < 7 or length(trim(p_phone)) > 40 then
    raise exception 'CHECKOUT_INVALID';
  end if;
  if jsonb_typeof(p_tickets) is distinct from 'array' then raise exception 'CHECKOUT_INVALID'; end if;
  if jsonb_array_length(p_tickets) < 1 or jsonb_array_length(p_tickets) > 4 then
    raise exception 'CHECKOUT_INVALID';
  end if;

  select * into v_passenger from public.passenger_profiles where user_id = p_user;
  if not found then raise exception 'PASSENGER_PROFILE_REQUIRED'; end if;

  select * into v_trip from public.trips
   where id = p_trip and status in ('scheduled', 'in_progress')
     and public._stop_departure(service_id, scheduled_departure, p_from_stop) > clock_timestamp() + interval '5 minutes'
     and (status = 'scheduled'
          or coalesce(public._trip_end_cutoff(service_id, (select d.route_id from public.service_departures d where d.id = departure_id), scheduled_departure), 'infinity'::timestamptz) > clock_timestamp())
   for update;
  if not found then raise exception 'TRIP_UNAVAILABLE'; end if;
  v_company_id := v_trip.company_id;
  if not exists (
    select 1 from public.mp_company_connections
     where company_id = v_company_id and active and test_mode
  ) then raise exception 'MERCADOPAGO_NOT_CONNECTED'; end if;

  select departure.route_id, route.name, service.code
    into v_route_id, v_route_name, v_service_code
    from public.service_departures departure
    join public.routes route on route.id = departure.route_id
    join public.services service on service.id = v_trip.service_id
   where departure.id = v_trip.departure_id
     and departure.service_id = v_trip.service_id
     and departure.company_id = v_company_id;
  if not found or v_trip.layout_id is null then raise exception 'TRIP_UNAVAILABLE'; end if;

  select position, name into v_from_pos, v_from_name
    from public.route_stops where id = p_from_stop and route_id = v_route_id;
  if not found then raise exception 'STOP_INVALID'; end if;
  select position, name into v_to_pos, v_to_name
    from public.route_stops where id = p_to_stop and route_id = v_route_id;
  if not found or v_from_pos >= v_to_pos then raise exception 'STOP_INVALID'; end if;

  update public.passenger_checkout_orders
     set status = 'expired'
   where trip_id = p_trip and status = 'pending' and expires_at <= clock_timestamp();

  for v_input in select value from jsonb_array_elements(p_tickets)
  loop
    v_index := v_index + 1;
    if jsonb_typeof(v_input) <> 'object'
       or coalesce(v_input ->> 'layout_cell_id', '') !~*
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'CHECKOUT_INVALID';
    end if;
    v_cell_id := (v_input ->> 'layout_cell_id')::uuid;
    if exists (
      select 1 from jsonb_array_elements(v_items) as stored(item)
       where stored.item ->> 'layout_cell_id' = v_cell_id::text
    ) then raise exception 'CHECKOUT_INVALID'; end if;

    select label, seat_class into v_seat_label, v_seat_class
      from public.layout_cells
     where id = v_cell_id and layout_id = v_trip.layout_id
       and kind = 'seat' and not blocked and not unusable;
    if not found or v_seat_label is null then raise exception 'SEAT_UNAVAILABLE'; end if;

    if v_index = 1 then
      v_passenger_name := trim(v_passenger.first_name || ' ' || v_passenger.last_name);
      v_passenger_dni := v_passenger.dni;
      v_passenger_email := v_passenger.email;
    else
      v_passenger_name := trim(coalesce(v_input ->> 'passenger_name', ''));
      v_passenger_dni := regexp_replace(trim(coalesce(v_input ->> 'passenger_dni', '')), '[^0-9]', '', 'g');
      v_passenger_email := lower(trim(coalesce(v_input ->> 'passenger_email', '')));
      if length(v_passenger_name) < 2 or length(v_passenger_name) > 150
         or v_passenger_dni !~ '^[0-9]{7,10}$'
         or v_passenger_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
        raise exception 'PASSENGER_INVALID';
      end if;
    end if;

    select price into v_price from public.ticket_prices
     where company_id = v_company_id and route_id = v_route_id
       and from_pos = v_from_pos and to_pos = v_to_pos and active and day_type = v_trip.fare_band
       and (seat_class is null or public.normalize_seat_class(seat_class)
         = public.normalize_seat_class(v_seat_class))
     order by (seat_class is not null) desc, created_at desc
     limit 1;
    if not found or v_price <= 0 then raise exception 'FARE_NOT_FOUND'; end if;

    if exists (
      select 1 from public.sale_tickets ticket
        join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
        join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
       where ticket.trip_id = p_trip and ticket.seat_label = v_seat_label
         and ticket.status in ('valid', 'boarded')
         and booked_from.position < v_to_pos and booked_to.position > v_from_pos
    ) or exists (
      select 1 from public.passenger_checkout_order_tickets held_ticket
        join public.passenger_checkout_orders held_order on held_order.id = held_ticket.order_id
        join public.route_stops held_from on held_from.id = held_ticket.from_stop_id
        join public.route_stops held_to on held_to.id = held_ticket.to_stop_id
       where held_ticket.trip_id = p_trip and held_ticket.seat_label = v_seat_label
         and held_order.status = 'pending' and held_order.expires_at > clock_timestamp()
         and held_from.position < v_to_pos and held_to.position > v_from_pos
    ) or exists (
      select 1 from public.passenger_checkout_orders legacy_order
        join public.route_stops held_from on held_from.id = legacy_order.from_stop_id
        join public.route_stops held_to on held_to.id = legacy_order.to_stop_id
       where legacy_order.trip_id = p_trip and legacy_order.seat_label = v_seat_label
         and legacy_order.status = 'pending' and legacy_order.expires_at > clock_timestamp()
         and held_from.position < v_to_pos and held_to.position > v_from_pos
         and not exists (
           select 1 from public.passenger_checkout_order_tickets held_ticket
            where held_ticket.order_id = legacy_order.id
         )
    ) then
      raise exception 'SEAT_TAKEN';
    end if;

    v_total := v_total + v_price;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'layout_cell_id', v_cell_id, 'seat_label', v_seat_label,
      'passenger_name', v_passenger_name, 'passenger_dni', v_passenger_dni,
      'passenger_email', v_passenger_email, 'passenger_phone', trim(p_phone),
      'price', v_price, 'from_stop_id', p_from_stop, 'to_stop_id', p_to_stop
    ));
  end loop;

  v_first := v_items -> 0;
  insert into public.passenger_checkout_orders (
    company_id, mp_connection_id, passenger_user_id, trip_id, from_stop_id, to_stop_id,
    layout_cell_id, seat_label, passenger_name, passenger_dni, passenger_email,
    passenger_phone, price
  ) values (
    v_company_id, v_company_id, p_user, p_trip, p_from_stop, p_to_stop,
    (v_first ->> 'layout_cell_id')::uuid, v_first ->> 'seat_label',
    v_first ->> 'passenger_name', v_first ->> 'passenger_dni', v_first ->> 'passenger_email',
    trim(p_phone), v_total
  ) returning id, expires_at into v_order_id, v_expires_at;

  insert into public.passenger_checkout_order_tickets (
    order_id, trip_id, from_stop_id, to_stop_id, layout_cell_id, seat_label,
    passenger_name, passenger_dni, passenger_email, passenger_phone, price
  )
  select v_order_id, p_trip, item.from_stop_id, item.to_stop_id, item.layout_cell_id,
         item.seat_label, item.passenger_name, item.passenger_dni, item.passenger_email,
         item.passenger_phone, item.price
    from jsonb_to_recordset(v_items) as item (
      layout_cell_id uuid, seat_label text, passenger_name text, passenger_dni text,
      passenger_email text, passenger_phone text, price numeric,
      from_stop_id uuid, to_stop_id uuid
    );

  return jsonb_build_object(
    'order_id', v_order_id, 'company_id', v_company_id, 'price', v_total,
    'service_code', v_service_code, 'route_name', v_route_name,
    'service_date', v_trip.service_date,
    'tickets', v_items, 'from_stop', v_from_name, 'to_stop', v_to_name,
    'expires_at', v_expires_at
  );
end
$function$;

CREATE OR REPLACE FUNCTION public._create_sale_with_tickets_impl(p_trip uuid, p_payment_method payment_method, p_notes text, p_passengers jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.current_company_id();
  v_trip public.trips;
  v_route uuid;
  v_sale_id uuid;
  v_total numeric(10,2) := 0;
  v_pass jsonb;
  v_name text;
  v_dni text;
  v_email text;
  v_phone text;
  v_from uuid;
  v_to uuid;
  v_from_pos int;
  v_to_pos int;
  v_cell uuid;
  v_seat_label text;
  v_seat_class text;
  v_is_complimentary boolean;
  v_price numeric(10,2);
  v_qr text;
  v_tickets jsonb := '[]'::jsonb;
begin
  if public.current_user_role() not in ('company_admin', 'seller') then raise exception 'FORBIDDEN'; end if;
  if p_trip is null or p_payment_method is null or jsonb_typeof(p_passengers) <> 'array'
     or jsonb_array_length(p_passengers) < 1 or jsonb_array_length(p_passengers) > 20 then
    raise exception 'SALE_INVALID: falta el viaje o los datos de los pasajeros';
  end if;

  select t.* into v_trip from public.trips t
   where t.id = p_trip and t.company_id = v_company
   for update;
  if not found then raise exception 'TRIP_NOT_FOUND'; end if;
  if v_trip.status not in ('scheduled', 'in_progress') then raise exception 'TRIP_CLOSED'; end if;

  select d.route_id into v_route from public.service_departures d
   where d.id = v_trip.departure_id and d.service_id = v_trip.service_id and d.company_id = v_company;
  if not found then raise exception 'ROUTE_INVALID'; end if;

  insert into public.sales (company_id, seller_id, trip_id, payment_method, total, notes)
  values (v_company, auth.uid(), p_trip, p_payment_method, 0, nullif(trim(p_notes), ''))
  returning id into v_sale_id;

  for v_pass in select value from jsonb_array_elements(p_passengers)
  loop
    v_name := trim(coalesce(v_pass ->> 'passenger_name', ''));
    v_dni := trim(coalesce(v_pass ->> 'passenger_dni', ''));
    v_email := lower(trim(coalesce(v_pass ->> 'passenger_email', '')));
    v_phone := trim(coalesce(v_pass ->> 'passenger_phone', ''));
    v_from := nullif(v_pass ->> 'from_stop_id', '')::uuid;
    v_to := nullif(v_pass ->> 'to_stop_id', '')::uuid;
    v_cell := nullif(v_pass ->> 'layout_cell_id', '')::uuid;
    v_seat_label := nullif(trim(coalesce(v_pass ->> 'seat_label', '')), '');
    v_is_complimentary := coalesce((v_pass ->> 'is_complimentary')::boolean, false);

    if length(v_name) < 2 or length(v_name) > 150 or length(v_dni) < 6
       or v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       or length(v_phone) < 7 or v_from is null or v_to is null then
      raise exception 'PASSENGER_INVALID: revisá los datos obligatorios del pasajero';
    end if;
    if v_trip.layout_id is not null and v_cell is null and not v_is_complimentary then
      raise exception 'SEAT_REQUIRED: seleccioná un asiento para este viaje';
    end if;

    select position into v_from_pos from public.route_stops where id = v_from and route_id = v_route;
    if not found then raise exception 'STOP_INVALID: origen fuera del recorrido'; end if;
    select position into v_to_pos from public.route_stops where id = v_to and route_id = v_route;
    if not found or v_from_pos >= v_to_pos then raise exception 'STOP_INVALID: destino debe ser posterior al origen'; end if;

    v_seat_class := null;
    if v_cell is not null or v_seat_label is not null then
      if v_trip.layout_id is null then raise exception 'SEAT_UNAVAILABLE: el viaje no tiene disposición asignada'; end if;
      if v_cell is null then
        select id into v_cell from public.layout_cells
         where layout_id = v_trip.layout_id and label = v_seat_label and kind = 'seat'
         limit 1;
      end if;
      select label, seat_class into v_seat_label, v_seat_class
        from public.layout_cells
       where id = v_cell and layout_id = v_trip.layout_id and kind = 'seat'
         and not blocked and not unusable;
      if not found or v_seat_label is null then raise exception 'SEAT_UNAVAILABLE: asiento inexistente o bloqueado'; end if;
      if exists (
        select 1
          from public.sale_tickets st
          join public.route_stops fs on fs.id = st.from_stop_id
          join public.route_stops ts on ts.id = st.to_stop_id
         where st.trip_id = p_trip and st.seat_label = v_seat_label
           and st.status in ('valid', 'boarded')
           and fs.position < v_to_pos and ts.position > v_from_pos
      ) then raise exception 'SEAT_TAKEN: el asiento ya está ocupado en parte de ese tramo'; end if;
    end if;

    if v_is_complimentary then
      v_price := 0;
    else
      select tp.price into v_price from public.ticket_prices tp
       where tp.company_id = v_company and tp.route_id = v_route
         and tp.from_pos = v_from_pos and tp.to_pos = v_to_pos and tp.active
         and tp.day_type = (select tr.fare_band from public.trips tr where tr.id = p_trip)
         and (tp.seat_class is null or public.normalize_seat_class(tp.seat_class)
           = public.normalize_seat_class(v_seat_class))
       order by (tp.seat_class is not null) desc, tp.created_at desc
       limit 1;
      if not found then raise exception 'FARE_NOT_FOUND: no hay tarifa activa para el tramo y clase seleccionados'; end if;
    end if;

    v_qr := gen_random_uuid()::text;
    insert into public.sale_tickets (
      company_id, sale_id, trip_id, seat_label, layout_cell_id,
      from_stop_id, to_stop_id, passenger_name, passenger_dni,
      passenger_email, passenger_phone, price, qr_code, is_complimentary, status
    ) values (
      v_company, v_sale_id, p_trip, v_seat_label, v_cell,
      v_from, v_to, v_name, v_dni, v_email, v_phone, v_price,
      v_qr, v_is_complimentary, 'valid'
    ) returning id into v_cell;
    v_total := v_total + v_price;
    v_tickets := v_tickets || jsonb_build_array(jsonb_build_object(
      'id', v_cell, 'qr_code', v_qr, 'passenger_name', v_name, 'seat_label', v_seat_label,
      'price', v_price, 'passenger_email', v_email
    ));
  end loop;

  if p_payment_method = 'complimentary'
     and exists (select 1 from public.sale_tickets where sale_id = v_sale_id and not is_complimentary) then
    raise exception 'PAYMENT_INVALID: una venta de cortesía solo puede contener pasajes gratuitos';
  end if;
  if p_payment_method <> 'complimentary'
     and not exists (select 1 from public.sale_tickets where sale_id = v_sale_id and not is_complimentary) then
    raise exception 'PAYMENT_INVALID: elegí cortesía para pasajes gratuitos';
  end if;

  update public.sales set total = v_total where id = v_sale_id;
  return jsonb_build_object('sale_id', v_sale_id, 'tickets', v_tickets, 'total', v_total);
end
$function$;

CREATE OR REPLACE FUNCTION public.taquilla_sell(p_trip uuid, p_payment_method payment_method, p_seats jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ctx record;
  v_seat jsonb;
  v_s record;
  v_sale uuid;
  v_fare numeric(10, 2);
  v_price numeric(10, 2);
  v_total numeric(10, 2) := 0;
  v_name text;
  v_dni text;
  v_qr text;
  v_id uuid;
  v_tickets jsonb := '[]'::jsonb;
  v_role text := public.current_user_role()::text;
  v_email text;
  v_phone text;
  v_ticket_type text;
  v_is_complimentary boolean;
  v_board boolean;
  v_event uuid;
begin
  if p_payment_method not in ('cash', 'transfer', 'debit', 'credit')
     or (v_role = 'driver' and p_payment_method in ('debit', 'credit')) then
    raise exception 'PAYMENT_INVALID: forma de pago no habilitada';
  end if;
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) < 1 or jsonb_array_length(p_seats) > 20 then
    raise exception 'SALE_INVALID: elegí al menos un asiento';
  end if;
  select * into v_ctx from public._taquilla_ctx(p_trip, true);
  -- venta del chofer en un viaje en curso: el pasajero sube ahora, así que se cuenta a bordo (como una lectura de QR)
  v_board := v_role = 'driver'
    and exists (select 1 from public.trips where id = p_trip and status = 'in_progress')
    and public.company_feature_enabled(v_ctx.o_company, 'counter');

  insert into public.sales (company_id, seller_id, trip_id, payment_method, total, notes)
  values (v_ctx.o_company, auth.uid(), p_trip, p_payment_method, 0, case when v_role = 'driver' then 'Venta en taquilla' else 'Venta en ventanilla' end)
  returning id into v_sale;

  for v_seat in select value from jsonb_array_elements(p_seats)
  loop
    select * into v_s from public._taquilla_seat(p_trip, v_ctx.o_route, v_ctx.o_layout, v_seat);
    select tp.price into v_fare from public.ticket_prices tp
     where tp.company_id = v_ctx.o_company and tp.route_id = v_ctx.o_route
       and tp.from_pos = v_s.o_from_pos and tp.to_pos = v_s.o_to_pos and tp.active
       and tp.day_type = (select tr.fare_band from public.trips tr where tr.id = p_trip)
       and (tp.seat_class is null or public.normalize_seat_class(tp.seat_class) = public.normalize_seat_class(v_s.o_class))
     order by (tp.seat_class is not null) desc, tp.created_at desc
     limit 1;
    if not found then raise exception 'FARE_NOT_FOUND: no hay tarifa activa para el tramo y clase seleccionados'; end if;

    v_ticket_type := coalesce(nullif(v_seat ->> 'ticket_type', ''), 'regular');
    if v_ticket_type not in ('regular', 'courtesy', 'disability') then
      raise exception 'TICKET_TYPE_INVALID: tipo de pasaje no válido';
    end if;
    if v_ticket_type <> 'regular' and v_role not in ('company_admin', 'seller') then
      raise exception 'FORBIDDEN: solo Ventanilla puede emitir pasajes de gentileza o discapacidad';
    end if;
    v_is_complimentary := v_ticket_type = 'courtesy';
    v_price := case when v_ticket_type = 'regular' then v_fare else 0 end;

    v_name := trim(coalesce(v_seat ->> 'passenger_name', ''));
    v_dni := regexp_replace(trim(coalesce(v_seat ->> 'passenger_dni', '')), '[^0-9]', '', 'g');
    if length(v_name) < 2 or length(v_name) > 150 or length(v_dni) < 6 then
      raise exception 'PASSENGER_INVALID: cargá nombre y apellido y DNI de cada pasajero';
    end if;
    v_email := lower(trim(coalesce(v_seat ->> 'passenger_email', '')));
    if v_email = '' then v_email := 'taquilla@pasajeros.ar';
    elsif v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(v_email) > 200 then
      raise exception 'PASSENGER_INVALID: el correo no es válido';
    end if;
    v_phone := regexp_replace(trim(coalesce(v_seat ->> 'passenger_phone', '')), '[^0-9+]', '', 'g');
    if length(v_phone) < 6 then v_phone := '0000000'; end if;
    v_qr := gen_random_uuid()::text;
    insert into public.sale_tickets (
      company_id, sale_id, trip_id, seat_label, layout_cell_id, from_stop_id, to_stop_id,
      passenger_name, passenger_dni, passenger_email, passenger_phone, price, qr_code, is_complimentary, ticket_type, status
    ) values (
      v_ctx.o_company, v_sale, p_trip, v_s.o_label, v_s.o_cell, v_s.o_from, v_s.o_to,
      v_name, v_dni, v_email, v_phone, v_price, v_qr, v_is_complimentary, v_ticket_type, 'valid'
    ) returning id into v_id;
    if v_board then
      v_event := gen_random_uuid();
      perform public.register_count(p_trip, 'board', 1, v_s.o_from, v_event);
      update public.sale_tickets
         set status = 'boarded', boarded_at = clock_timestamp(), boarded_by = auth.uid(),
             actual_boarding_stop_id = v_s.o_from, boarding_event_id = v_event
       where id = v_id;
    end if;
    v_total := v_total + v_price;
    v_tickets := v_tickets || jsonb_build_array(jsonb_build_object(
      'id', v_id, 'qr_code', v_qr, 'seat_label', v_s.o_label, 'price', v_price,
      'passenger_name', v_name, 'passenger_dni', v_dni, 'email', case when v_email = 'taquilla@pasajeros.ar' then null else v_email end,
      'from_stop_id', v_s.o_from, 'to_stop_id', v_s.o_to, 'ticket_type', v_ticket_type, 'boarded', v_board));
  end loop;

  update public.sales
     set total = v_total,
         payment_method = case when v_total = 0 then 'complimentary'::public.payment_method else p_payment_method end
   where id = v_sale;
  delete from public.seat_holds where trip_id = p_trip and (held_by = auth.uid() or expires_at <= clock_timestamp());
  return jsonb_build_object('sale_id', v_sale, 'tickets', v_tickets, 'total', v_total);
end $function$;

CREATE OR REPLACE FUNCTION public._public_company_trips_impl(p_company uuid, p_from_place uuid DEFAULT NULL::uuid, p_to_place uuid DEFAULT NULL::uuid, p_date date DEFAULT NULL::date, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10)
 RETURNS TABLE(trip_id uuid, company_name text, service_code text, route_name text, service_date date, scheduled_departure timestamp with time zone, from_stop_id uuid, from_stop_name text, to_stop_id uuid, to_stop_name text, price numeric, available_seats integer, origin_place_id uuid, destination_place_id uuid, total_count bigint, in_transit boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_today date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  if p_company is null or not exists (
    select 1 from public.companies company
     where company.id = p_company and company.active
  ) then
    raise exception 'COMPANY_INVALID';
  end if;
  if (p_from_place is null) <> (p_to_place is null)
     or (p_from_place is not null and p_from_place = p_to_place) then
    raise exception 'PLACES_INVALID: elegí un origen y un destino distintos';
  end if;
  if p_date is not null and (p_date < v_today or p_date > v_today + 180) then
    raise exception 'DATE_INVALID: la fecha debe estar dentro de los próximos 180 días';
  end if;
  if p_page is null or p_page < 1 or p_page_size is null or p_page_size not between 1 and 20 then
    raise exception 'PAGINATION_INVALID';
  end if;

  return query
  select trip.id, company.name, service.code, route.name,
         trip.service_date, segment.segment_departure,
         segment.from_stop_id, from_place.name, segment.to_stop_id, to_place.name,
         fare.price,
         greatest(coalesce(capacity.seats, 0) - coalesce(reserved.count, 0), 0)::int,
         segment.from_place_id, segment.to_place_id, count(*) over (),
         (trip.status = 'in_progress' and segment.segment_departure <= now() + interval '5 minutes')
    from public.trips trip
    join public.companies company on company.id = trip.company_id and company.active
    join public.services service on service.id = trip.service_id and service.active
    join public.service_departures departure
      on departure.id = trip.departure_id and departure.active
    join public.routes route
      on route.id = departure.route_id and route.active and route.company_id = trip.company_id
    join lateral (
      select from_stop.id as from_stop_id, from_stop.place_id as from_place_id,
             from_stop.position as from_position,
             trip.scheduled_departure + make_interval(mins => coalesce(source_time.minutes_from_start, 0) + coalesce(source_time.dwell_minutes, 0)) as segment_departure,
             to_stop.id as to_stop_id, to_stop.place_id as to_place_id,
             to_stop.position as to_position
        from public.route_stops from_stop
        join public.route_stops to_stop
          on to_stop.route_id = from_stop.route_id
         and from_stop.position < to_stop.position
        left join public.service_stops source_time
         on source_time.service_id = trip.service_id and source_time.route_stop_id = from_stop.id
       left join lateral (
          select min(ticket_price.price) as price
            from public.ticket_prices ticket_price
           where ticket_price.company_id = p_company
             and ticket_price.route_id = route.id
             and ticket_price.from_pos = from_stop.position
             and ticket_price.to_pos = to_stop.position
             and ticket_price.active and ticket_price.day_type = trip.fare_band
        ) pair_fare on true
       where from_stop.route_id = route.id
         and (
           (p_from_place is not null
            and from_stop.place_id = p_from_place
            and to_stop.place_id = p_to_place
            and (from_stop.position = (select min(first_stop.position) from public.route_stops first_stop where first_stop.route_id = route.id)
                 or coalesce(source_time.publish_from_web, false)))
           or
           (p_from_place is null
            and (from_stop.position = (
              select min(first_stop.position)
                from public.route_stops first_stop
               where first_stop.route_id = route.id
            ) or coalesce(source_time.publish_from_web, false))
            and to_stop.position = (
              select max(last_stop.position)
                from public.route_stops last_stop
               where last_stop.route_id = route.id
            ))
         )
       order by (pair_fare.price is null), pair_fare.price,
                from_stop.position, to_stop.position desc
       limit case when p_from_place is null then 2147483647 else 1 end
    ) segment on true
    join public.places from_place on from_place.id = segment.from_place_id
    join public.places to_place on to_place.id = segment.to_place_id
    left join lateral (
      select count(*) as seats
        from public.layout_cells cell
       where cell.layout_id = trip.layout_id and cell.kind = 'seat'
         and not cell.blocked and not cell.unusable
    ) capacity on true
    left join lateral (
      select count(distinct occupied.seat_label) as count
        from (
          select ticket.seat_label
            from public.sale_tickets ticket
            join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
            join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
           where ticket.trip_id = trip.id and ticket.status in ('valid', 'boarded')
             and booked_from.position < segment.to_position
             and booked_to.position > segment.from_position
          union
          select item.seat_label
            from public.passenger_checkout_order_tickets item
            join public.passenger_checkout_orders hold on hold.id = item.order_id
            join public.route_stops held_from on held_from.id = item.from_stop_id
            join public.route_stops held_to on held_to.id = item.to_stop_id
           where item.trip_id = trip.id and hold.status = 'pending'
             and hold.expires_at > now()
             and held_from.position < segment.to_position
             and held_to.position > segment.from_position
          union
          select hold.seat_label
            from public.passenger_checkout_orders hold
            join public.route_stops held_from on held_from.id = hold.from_stop_id
            join public.route_stops held_to on held_to.id = hold.to_stop_id
           where hold.trip_id = trip.id and hold.status = 'pending'
             and hold.expires_at > now()
             and held_from.position < segment.to_position
             and held_to.position > segment.from_position
             and not exists (
               select 1 from public.passenger_checkout_order_tickets item
                where item.order_id = hold.id
             )
        ) occupied
    ) reserved on true
    left join lateral (
      select min(ticket_price.price) as price
        from public.ticket_prices ticket_price
       where ticket_price.company_id = trip.company_id
         and ticket_price.route_id = route.id
         and ticket_price.from_pos = segment.from_position
         and ticket_price.to_pos = segment.to_position
         and ticket_price.active and ticket_price.day_type = trip.fare_band
    ) fare on true
   where trip.company_id = p_company
     and trip.service_date between v_today - 1 and v_today + 180
     and (segment.segment_departure at time zone 'America/Argentina/Buenos_Aires')::date >= v_today
     and (p_date is null or (segment.segment_departure at time zone 'America/Argentina/Buenos_Aires')::date = p_date)
     and trip.published_at is not null
     and (
       (trip.status = 'scheduled' and segment.segment_departure > now() + interval '5 minutes')
       or (trip.status = 'in_progress'
           and coalesce(public._trip_end_cutoff(trip.service_id, route.id, trip.scheduled_departure), 'infinity'::timestamptz) > now())
     )
     and trip.day_type = any (departure.day_types)
     and (coalesce(capacity.seats, 0) > coalesce(reserved.count, 0)
          or (trip.status = 'in_progress' and segment.segment_departure <= now() + interval '5 minutes'))
   order by segment.segment_departure, route.name, service.code
   limit p_page_size
  offset (p_page - 1) * p_page_size;
end
$function$;

CREATE OR REPLACE FUNCTION public._public_search_trips_impl(p_from_place uuid, p_to_place uuid, p_date date, p_company uuid DEFAULT NULL::uuid)
 RETURNS TABLE(trip_id uuid, company_name text, service_code text, route_name text, service_date date, scheduled_departure timestamp with time zone, from_stop_id uuid, from_stop_name text, to_stop_id uuid, to_stop_name text, price numeric, available_seats integer, in_transit boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_from_place is null or p_to_place is null or p_from_place = p_to_place then
    raise exception 'PLACES_INVALID: elegí un origen y un destino distintos';
  end if;
  if p_date is null or p_date < (now() at time zone 'America/Argentina/Buenos_Aires')::date
     or p_date > (now() at time zone 'America/Argentina/Buenos_Aires')::date + 180 then
    raise exception 'DATE_INVALID: la fecha debe estar dentro de los próximos 180 días';
  end if;

  return query
  select trip.id, company.name, service.code, route.name,
         trip.service_date, segment.segment_departure,
         segment.from_stop_id, from_place.name, segment.to_stop_id, to_place.name,
         fare.price,
         greatest(coalesce(capacity.seats, 0) - coalesce(reserved.count, 0), 0)::int,
         (trip.status = 'in_progress' and segment.segment_departure <= now() + interval '5 minutes')
    from public.trips trip
    join public.companies company on company.id = trip.company_id and company.active
    join public.services service on service.id = trip.service_id and service.active
    join public.service_departures departure
      on departure.id = trip.departure_id and departure.active
    join public.routes route
      on route.id = departure.route_id and route.active and route.company_id = trip.company_id
    join public.places from_place on from_place.id = p_from_place
    join public.places to_place on to_place.id = p_to_place
    join lateral (
      select from_stop.id as from_stop_id, from_stop.position as from_position,
             trip.scheduled_departure + make_interval(mins => coalesce(source_time.minutes_from_start, 0) + coalesce(source_time.dwell_minutes, 0)) as segment_departure,
             to_stop.id as to_stop_id, to_stop.position as to_position
        from public.route_stops from_stop
        join public.route_stops to_stop
          on to_stop.route_id = from_stop.route_id
         and to_stop.place_id = p_to_place
         and from_stop.position < to_stop.position
        left join public.service_stops source_time
          on source_time.service_id = trip.service_id and source_time.route_stop_id = from_stop.id
        left join lateral (
          select min(ticket_price.price) as price
            from public.ticket_prices ticket_price
           where ticket_price.company_id = trip.company_id
             and ticket_price.route_id = route.id
             and ticket_price.from_pos = from_stop.position
             and ticket_price.to_pos = to_stop.position
             and ticket_price.active and ticket_price.day_type = trip.fare_band
        ) pair_fare on true
       where from_stop.route_id = route.id
         and from_stop.place_id = p_from_place
       order by (pair_fare.price is null), pair_fare.price,
                from_stop.position, to_stop.position desc
       limit 1
    ) segment on true
    left join lateral (
      select count(*) as seats
        from public.layout_cells cell
       where cell.layout_id = trip.layout_id and cell.kind = 'seat'
         and not cell.blocked and not cell.unusable
    ) capacity on true
    left join lateral (
      select count(distinct occupied.seat_label) as count
        from (
          select ticket.seat_label
            from public.sale_tickets ticket
            join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
            join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
           where ticket.trip_id = trip.id and ticket.status in ('valid', 'boarded')
             and booked_from.position < segment.to_position
             and booked_to.position > segment.from_position
          union
          select item.seat_label
            from public.passenger_checkout_order_tickets item
            join public.passenger_checkout_orders hold on hold.id = item.order_id
            join public.route_stops held_from on held_from.id = item.from_stop_id
            join public.route_stops held_to on held_to.id = item.to_stop_id
           where item.trip_id = trip.id and hold.status = 'pending'
             and hold.expires_at > now()
             and held_from.position < segment.to_position
             and held_to.position > segment.from_position
          union
          select hold.seat_label
            from public.passenger_checkout_orders hold
            join public.route_stops held_from on held_from.id = hold.from_stop_id
            join public.route_stops held_to on held_to.id = hold.to_stop_id
           where hold.trip_id = trip.id and hold.status = 'pending'
             and hold.expires_at > now()
             and held_from.position < segment.to_position
             and held_to.position > segment.from_position
             and not exists (
               select 1 from public.passenger_checkout_order_tickets item
                where item.order_id = hold.id
             )
        ) occupied
    ) reserved on true
    left join lateral (
      select min(ticket_price.price) as price
        from public.route_stops fare_from
        join public.route_stops fare_to
          on fare_to.route_id = fare_from.route_id
         and fare_to.position > fare_from.position
        join public.ticket_prices ticket_price
          on ticket_price.company_id = trip.company_id
         and ticket_price.route_id = route.id
         and ticket_price.from_pos = fare_from.position
         and ticket_price.to_pos = fare_to.position
         and ticket_price.active and ticket_price.day_type = trip.fare_band
       where fare_from.route_id = route.id
         and fare_from.place_id = p_from_place
         and fare_to.place_id = p_to_place
    ) fare on true
   where trip.service_date between p_date - 1 and p_date
     and (segment.segment_departure at time zone 'America/Argentina/Buenos_Aires')::date = p_date
     and trip.published_at is not null
     and (
       (trip.status = 'scheduled' and segment.segment_departure > now() + interval '5 minutes')
       or (trip.status = 'in_progress'
           and coalesce(public._trip_end_cutoff(trip.service_id, route.id, trip.scheduled_departure), 'infinity'::timestamptz) > now())
     )
     and trip.day_type = any (departure.day_types)
     and (coalesce(capacity.seats, 0) > coalesce(reserved.count, 0)
          or (trip.status = 'in_progress' and segment.segment_departure <= now() + interval '5 minutes'))
     and (p_company is null or trip.company_id = p_company)
   order by segment.segment_departure, company.name;
end
$function$;

CREATE OR REPLACE FUNCTION public._public_trip_seats_impl(p_trip uuid, p_from_stop uuid, p_to_stop uuid)
 RETURNS TABLE(cell_id uuid, floor integer, row_idx integer, col_idx integer, seat_label text, seat_class text, available boolean, price numeric, cell_kind text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_route uuid;
  v_layout uuid;
  v_company uuid;
  v_from_pos int;
  v_to_pos int;
begin
  select departure.route_id, trip.layout_id, trip.company_id
    into v_route, v_layout, v_company
    from public.trips trip
    join public.service_departures departure on departure.id = trip.departure_id
   where trip.id = p_trip
     and trip.status in ('scheduled', 'in_progress')
     and public._stop_departure(trip.service_id, trip.scheduled_departure, p_from_stop) > now() + interval '5 minutes'
     and (trip.status = 'scheduled'
          or coalesce(public._trip_end_cutoff(trip.service_id, departure.route_id, trip.scheduled_departure), 'infinity'::timestamptz) > now());
  if not found or v_layout is null then return; end if;

  select stop.position into v_from_pos
    from public.route_stops stop
   where stop.id = p_from_stop and stop.route_id = v_route;
  select stop.position into v_to_pos
    from public.route_stops stop
   where stop.id = p_to_stop and stop.route_id = v_route;
  if v_from_pos is null or v_to_pos is null or v_from_pos >= v_to_pos then
    raise exception 'STOPS_INVALID';
  end if;

  return query
  select cell.id, cell.floor, cell.row_idx, cell.col_idx + 1, cell.label, cell.seat_class,
         case when cell.kind = 'seat' and not cell.blocked and not cell.unusable then
           not exists (
             select 1 from public.sale_tickets ticket
               join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
               join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
              where ticket.trip_id = p_trip and ticket.seat_label = cell.label
                and ticket.status in ('valid', 'boarded')
                and booked_from.position < v_to_pos and booked_to.position > v_from_pos
           ) and not exists (
             select 1 from public.passenger_checkout_order_tickets item
               join public.passenger_checkout_orders hold on hold.id = item.order_id
               join public.route_stops held_from on held_from.id = item.from_stop_id
               join public.route_stops held_to on held_to.id = item.to_stop_id
              where item.trip_id = p_trip and item.seat_label = cell.label
                and hold.status = 'pending' and hold.expires_at > now()
                and held_from.position < v_to_pos and held_to.position > v_from_pos
           ) and not exists (
             select 1 from public.passenger_checkout_orders hold
               join public.route_stops held_from on held_from.id = hold.from_stop_id
               join public.route_stops held_to on held_to.id = hold.to_stop_id
              where hold.trip_id = p_trip and hold.seat_label = cell.label
                and hold.status = 'pending' and hold.expires_at > now()
                and held_from.position < v_to_pos and held_to.position > v_from_pos
                and not exists (
                  select 1 from public.passenger_checkout_order_tickets item
                   where item.order_id = hold.id
                )
           )
         else false end,
         case when cell.kind = 'seat' and not cell.blocked and not cell.unusable then
           coalesce(class_fare.price, base_fare.price)
         end,
         cell.kind::text
    from public.layout_cells cell
    left join lateral (
      select ticket_price.price
        from public.ticket_prices ticket_price
       where ticket_price.company_id = v_company and ticket_price.route_id = v_route
         and ticket_price.from_pos = v_from_pos and ticket_price.to_pos = v_to_pos
         and public.normalize_seat_class(ticket_price.seat_class)
           = public.normalize_seat_class(cell.seat_class)
         and ticket_price.active
         and ticket_price.day_type = (select tr.fare_band from public.trips tr where tr.id = p_trip)
       order by ticket_price.created_at desc
       limit 1
    ) class_fare on true
    left join lateral (
      select ticket_price.price
        from public.ticket_prices ticket_price
       where ticket_price.company_id = v_company and ticket_price.route_id = v_route
         and ticket_price.from_pos = v_from_pos and ticket_price.to_pos = v_to_pos
         and ticket_price.seat_class is null and ticket_price.active
         and ticket_price.day_type = (select tr.fare_band from public.trips tr where tr.id = p_trip)
       order by ticket_price.created_at desc
       limit 1
    ) base_fare on true
   where cell.layout_id = v_layout
   order by cell.floor, cell.row_idx, cell.col_idx;
end
$function$;

CREATE OR REPLACE FUNCTION public._save_ticket_price_impl(p_route uuid, p_from_pos integer, p_to_pos integer, p_price numeric, p_seat_class text, p_day_type text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.current_company_id();
  v_id uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_route is null or p_from_pos < 1 or p_to_pos <= p_from_pos or p_price < 0 or p_day_type is null or not exists (select 1 from public.fare_bands fb where fb.company_id = public.current_company_id() and fb.code = p_day_type) then
    raise exception 'PRICE_INVALID: revisá el tramo y el precio';
  end if;
  if not exists (
    select 1 from public.service_departures departure
     where departure.route_id = p_route and departure.company_id = v_company
       and exists (select 1 from public.route_stops stop where stop.route_id = p_route and stop.position = p_from_pos)
       and exists (select 1 from public.route_stops stop where stop.route_id = p_route and stop.position = p_to_pos)
  ) then raise exception 'ROUTE_INVALID: el tramo no pertenece a un recorrido de tu empresa'; end if;

  perform 1 from public.companies where id = v_company for update;
  select price.id into v_id
    from public.ticket_prices price
   where price.company_id = v_company and price.route_id = p_route
     and price.from_pos = p_from_pos and price.to_pos = p_to_pos
     and public.normalize_seat_class(price.seat_class)
       is not distinct from public.normalize_seat_class(p_seat_class)
     and price.day_type = p_day_type
   order by price.created_at desc
   limit 1 for update;
  if p_price is null then
    -- sin precio: ese tipo de día no se vende en el tramo
    update public.ticket_prices set active = false where id = v_id;
    return v_id;
  end if;
  if v_id is null then
    insert into public.ticket_prices (company_id, route_id, from_pos, to_pos, price, seat_class, day_type)
    values (v_company, p_route, p_from_pos, p_to_pos, p_price, nullif(trim(p_seat_class), ''), p_day_type)
    returning id into v_id;
  else
    update public.ticket_prices set price = p_price, active = true where id = v_id;
  end if;
  return v_id;
end
$function$;

CREATE OR REPLACE FUNCTION public._pass_redeem(p_pass uuid, p_trip uuid, p_from uuid, p_to uuid, p_label text, p_channel text, p_seller uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_pass public.passes;
  v_trip public.trips;
  v_route uuid;
  v_s record;
  v_pa uuid;
  v_pb uuid;
  v_sale uuid;
  v_ticket uuid;
  v_qr text := gen_random_uuid()::text;
begin
  select * into v_pass from public.passes where id = p_pass for update;
  if not found or v_pass.status <> 'active' then raise exception 'PASS_NOT_FOUND: el abono no existe o fue dado de baja'; end if;
  select * into v_trip from public.trips where id = p_trip and company_id = v_pass.company_id for update;
  if not found then raise exception 'TRIP_NOT_FOUND'; end if;
  if v_trip.status not in ('scheduled', 'in_progress') then raise exception 'TRIP_CLOSED'; end if;
  if v_pass.trips_left < 1 then raise exception 'PASS_EMPTY: el abono no tiene viajes disponibles'; end if;
  if clock_timestamp() >= v_pass.expires_at then raise exception 'PASS_EXPIRED: el abono está vencido'; end if;
  if v_trip.scheduled_departure > v_pass.expires_at then
    raise exception 'PASS_EXPIRES_BEFORE_TRIP: el abono vence antes de la salida de este viaje';
  end if;
  select d.route_id into v_route from public.service_departures d
   where d.id = v_trip.departure_id and d.service_id = v_trip.service_id and d.company_id = v_trip.company_id;
  if not found then raise exception 'ROUTE_INVALID'; end if;
  if not (v_trip.fare_band = any (v_pass.day_types)) then
    raise exception 'PASS_DAY_MISMATCH: el abono no vale para esta franja horaria';
  end if;

  select * into v_s from public._taquilla_seat(p_trip, v_route, v_trip.layout_id,
    jsonb_build_object('seat_label', p_label, 'from_stop_id', p_from, 'to_stop_id', p_to));

  select place_id into v_pa from public.route_stops where id = p_from;
  select place_id into v_pb from public.route_stops where id = p_to;
  if v_pa is null or v_pb is null
     or not ((v_pa = v_pass.place_a and v_pb = v_pass.place_b) or (v_pa = v_pass.place_b and v_pb = v_pass.place_a)) then
    raise exception 'PASS_ROUTE_MISMATCH: el abono no vale para este tramo';
  end if;
  if v_pass.seat_class is not null
     and public.normalize_seat_class(v_s.o_class) is distinct from public.normalize_seat_class(v_pass.seat_class) then
    raise exception 'PASS_CLASS_MISMATCH: el abono no vale para esta clase de asiento';
  end if;

  insert into public.sales (company_id, seller_id, trip_id, payment_method, total, notes, channel)
  values (v_pass.company_id, p_seller, p_trip, 'pass', 0, 'Pasaje con abono', p_channel)
  returning id into v_sale;
  insert into public.sale_tickets (
    company_id, sale_id, trip_id, seat_label, layout_cell_id, from_stop_id, to_stop_id,
    passenger_name, passenger_dni, passenger_email, passenger_phone, price, qr_code, ticket_type, status, pass_id
  ) values (
    v_pass.company_id, v_sale, p_trip, v_s.o_label, v_s.o_cell, v_s.o_from, v_s.o_to,
    v_pass.holder_name, v_pass.holder_dni, coalesce(v_pass.holder_email, 'abono@pasajeros.ar'), '0000000', 0, v_qr,
    'regular', 'valid', v_pass.id
  ) returning id into v_ticket;
  update public.passes set trips_left = trips_left - 1 where id = v_pass.id;
  insert into public.pass_movements (pass_id, kind, delta, ticket_id) values (v_pass.id, 'use', -1, v_ticket);
  return jsonb_build_object('sale_id', v_sale, 'ticket_id', v_ticket, 'qr_code', v_qr, 'seat_label', v_s.o_label,
    'trips_left', v_pass.trips_left - 1, 'expires_at', v_pass.expires_at);
end $function$;

CREATE OR REPLACE FUNCTION public.trip_day_type(p_trip uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select fare_band from public.trips where id = p_trip and published_at is not null
$function$;

CREATE OR REPLACE FUNCTION public.pass_days_short(p_days text[]) RETURNS text
 LANGUAGE sql IMMUTABLE
AS $function$
  select case when p_days @> array['weekday','saturday','sunday','holiday'] and cardinality(p_days) = 4 then ''
    else ' · días ' || (select string_agg(case x when 'weekday' then 'H' when 'saturday' then 'S' when 'sunday' then 'D' when 'holiday' then 'F'
                                                else initcap(replace(x, '-', ' ')) end, '·' order by case x when 'weekday' then 1 when 'saturday' then 2 when 'sunday' then 3 when 'holiday' then 4 else 5 end, x) from unnest(p_days) x) end
$function$;
