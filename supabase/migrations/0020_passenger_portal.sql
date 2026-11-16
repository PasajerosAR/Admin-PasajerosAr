create table public.passenger_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  first_name text not null check (length(trim(first_name)) between 2 and 80),
  last_name text not null check (length(trim(last_name)) between 2 and 80),
  dni text not null check (dni ~ '^[0-9]{7,10}$'),
  birth_date date not null check (birth_date <= current_date and birth_date >= date '1900-01-01'),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  created_at timestamptz not null default now(),
  unique (dni)
);
create unique index passenger_profiles_email_idx on public.passenger_profiles (lower(email));
alter table public.passenger_profiles enable row level security;
create policy passenger_profiles_self_select on public.passenger_profiles for select to authenticated
  using (user_id = auth.uid());
grant select on public.passenger_profiles to authenticated;

create function public.create_passenger_profile_from_auth()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  if coalesce(v_meta ->> 'account_type', '') <> 'passenger' then return new; end if;
  if new.email is null or length(trim(coalesce(v_meta ->> 'first_name', ''))) < 2
     or length(trim(coalesce(v_meta ->> 'last_name', ''))) < 2
     or coalesce(v_meta ->> 'dni', '') !~ '^[0-9]{7,10}$'
     or coalesce(v_meta ->> 'birth_date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'PASSENGER_PROFILE_INVALID: revisá nombre, apellido, DNI, fecha de nacimiento y correo';
  end if;
  insert into public.passenger_profiles (user_id, first_name, last_name, dni, birth_date, email)
  values (
    new.id,
    trim(v_meta ->> 'first_name'),
    trim(v_meta ->> 'last_name'),
    v_meta ->> 'dni',
    (v_meta ->> 'birth_date')::date,
    lower(trim(new.email))
  );
  return new;
end
$$;
create trigger create_passenger_profile_after_signup
  after insert on auth.users for each row execute function public.create_passenger_profile_from_auth();

alter table public.sale_tickets
  add column passenger_user_id uuid references auth.users (id) on delete set null;
create index sale_tickets_passenger_idx on public.sale_tickets (passenger_user_id, created_at desc);
create policy st_passenger_select on public.sale_tickets for select to authenticated
  using (passenger_user_id = auth.uid());
grant select on public.sale_tickets to authenticated;

create function public.link_sale_ticket_to_passenger()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.passenger_user_id is null then
    select pp.user_id into new.passenger_user_id
      from public.passenger_profiles pp
     where lower(pp.email) = lower(trim(new.passenger_email))
       and pp.dni = regexp_replace(trim(new.passenger_dni), '[^0-9]', '', 'g')
     limit 1;
  end if;
  return new;
end
$$;
create trigger sale_ticket_link_passenger
  before insert on public.sale_tickets for each row execute function public.link_sale_ticket_to_passenger();

create or replace function public.passenger_places()
returns table (place_id uuid, place_name text, province text)
language sql stable security definer set search_path = public as $$
  select id, name, places.province from public.places order by name
$$;
revoke all on function public.passenger_places() from public;
grant execute on function public.passenger_places() to anon, authenticated;

create function public.passenger_my_tickets()
returns table (
  ticket_id uuid, trip_id uuid, trip_status public.trip_status, service_code text, company_name text, route_name text,
  service_date date, scheduled_departure timestamptz, from_stop text, to_stop text,
  seat_label text, price numeric, passenger_name text, passenger_dni text,
  passenger_email text, qr_code text, ticket_status public.ticket_status,
  sale_id uuid, created_at timestamptz
)
language plpgsql security definer set search_path = public as $$
declare
  v_passenger public.passenger_profiles;
begin
  select * into v_passenger from public.passenger_profiles where user_id = auth.uid();
  if not found then return; end if;

  update public.sale_tickets set passenger_user_id = auth.uid()
   where passenger_user_id is null
     and lower(passenger_email) = lower(v_passenger.email)
     and regexp_replace(trim(passenger_dni), '[^0-9]', '', 'g') = v_passenger.dni;

  return query
  select st.id, t.id, t.status, s.code, c.name, r.name, t.service_date, t.scheduled_departure,
         fs.name, ts.name, st.seat_label, st.price, st.passenger_name, st.passenger_dni,
         st.passenger_email, st.qr_code, st.status, st.sale_id, st.created_at
    from public.sale_tickets st
    join public.trips t on t.id = st.trip_id
    join public.services s on s.id = t.service_id
    join public.companies c on c.id = t.company_id
    join public.service_departures d on d.id = t.departure_id
    join public.routes r on r.id = d.route_id
    join public.route_stops fs on fs.id = st.from_stop_id
    join public.route_stops ts on ts.id = st.to_stop_id
   where st.passenger_user_id = auth.uid()
   order by st.created_at desc;
end
$$;
revoke all on function public.passenger_my_tickets() from public, anon;
grant execute on function public.passenger_my_tickets() to authenticated;

create function public.public_search_trips(p_from_place uuid, p_to_place uuid, p_date date)
returns table (
  trip_id uuid, company_name text, service_code text, route_name text,
  service_date date, scheduled_departure timestamptz, from_stop_id uuid,
  from_stop_name text, to_stop_id uuid, to_stop_name text, price numeric,
  available_seats int
)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_from_place is null or p_to_place is null or p_from_place = p_to_place then
    raise exception 'PLACES_INVALID: elegí un origen y un destino distintos';
  end if;
  if p_date is null or p_date < (now() at time zone 'America/Argentina/Buenos_Aires')::date
     or p_date > (now() at time zone 'America/Argentina/Buenos_Aires')::date + 180 then
    raise exception 'DATE_INVALID: la fecha debe estar dentro de los próximos 180 días';
  end if;
  return query
  select t.id, c.name, s.code, r.name, t.service_date, t.scheduled_departure,
         fs.id, fs.name, ts.id, ts.name, fare.price,
         greatest(coalesce(cap.seats, 0) - coalesce(sold.count, 0), 0)::int
    from public.trips t
    join public.companies c on c.id = t.company_id and c.active
    join public.services s on s.id = t.service_id and s.active
    join public.service_departures d on d.id = t.departure_id and d.active
    join public.routes r on r.id = d.route_id and r.active and r.company_id = t.company_id
    join public.route_stops fs on fs.route_id = r.id and fs.place_id = p_from_place
    join public.route_stops ts on ts.route_id = r.id and ts.place_id = p_to_place and fs.position < ts.position
    left join public.seat_layout_capacity cap on cap.layout_id = t.layout_id
    left join lateral (
      select count(*) as count from public.sale_tickets st
       where st.trip_id = t.id and st.status in ('valid', 'boarded')
    ) sold on true
    left join lateral (
      select tp.price from public.ticket_prices tp
       where tp.company_id = t.company_id and tp.route_id = r.id
         and tp.from_pos = fs.position and tp.to_pos = ts.position
         and tp.active and tp.seat_class is null
       order by tp.created_at desc limit 1
    ) fare on true
   where t.service_date = p_date and t.status = 'scheduled'
     and t.scheduled_departure > now()
     and public.day_type_of(t.service_date) = any (d.day_types)
   order by t.scheduled_departure, c.name;
end
$$;
revoke all on function public.public_search_trips(uuid, uuid, date) from public;
grant execute on function public.public_search_trips(uuid, uuid, date) to anon, authenticated;

create function public.public_trip_stops(p_trip uuid, p_from_stop uuid, p_to_stop uuid)
returns table (stop_id uuid, stop_name text, stop_position int, minutes_from_start int)
language sql stable security definer set search_path = public as $$
  select rs.id, rs.name, rs.position, coalesce(ss.minutes_from_start, 0)
    from public.trips t
    join public.service_departures d on d.id = t.departure_id
    join public.route_stops first_stop on first_stop.id = p_from_stop and first_stop.route_id = d.route_id
    join public.route_stops last_stop on last_stop.id = p_to_stop and last_stop.route_id = d.route_id
    join public.route_stops rs on rs.route_id = d.route_id
    left join public.service_stops ss on ss.service_id = t.service_id and ss.route_stop_id = rs.id
   where t.id = p_trip and first_stop.position <= rs.position and rs.position <= last_stop.position
     and first_stop.position < last_stop.position
   order by rs.position
$$;
revoke all on function public.public_trip_stops(uuid, uuid, uuid) from public;
grant execute on function public.public_trip_stops(uuid, uuid, uuid) to anon, authenticated;

create function public.public_trip_seats(
  p_trip uuid, p_from_stop uuid, p_to_stop uuid
) returns table (cell_id uuid, seat_label text, seat_class text, available boolean, price numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  v_route uuid;
  v_layout uuid;
  v_company uuid;
  v_from_pos int;
  v_to_pos int;
begin
  select d.route_id, t.layout_id, t.company_id into v_route, v_layout, v_company
    from public.trips t join public.service_departures d on d.id = t.departure_id
   where t.id = p_trip and t.status = 'scheduled' and t.scheduled_departure > now();
  if not found or v_layout is null then return; end if;
  select position into v_from_pos from public.route_stops where id = p_from_stop and route_id = v_route;
  select position into v_to_pos from public.route_stops where id = p_to_stop and route_id = v_route;
  if v_from_pos is null or v_to_pos is null or v_from_pos >= v_to_pos then
    raise exception 'STOPS_INVALID';
  end if;
  return query
  select cell.id, cell.label, cell.seat_class,
         not exists (
           select 1
             from public.sale_tickets st
             join public.route_stops booked_from on booked_from.id = st.from_stop_id
             join public.route_stops booked_to on booked_to.id = st.to_stop_id
            where st.trip_id = p_trip and st.seat_label = cell.label
              and st.status in ('valid', 'boarded')
              and booked_from.position < v_to_pos and booked_to.position > v_from_pos
         ) as available,
         coalesce(class_fare.price, base_fare.price) as price
    from public.layout_cells cell
    left join lateral (
      select tp.price from public.ticket_prices tp
       where tp.company_id = v_company and tp.route_id = v_route
         and tp.from_pos = v_from_pos and tp.to_pos = v_to_pos
         and tp.seat_class = cell.seat_class and tp.active
       order by tp.created_at desc limit 1
    ) class_fare on true
    left join lateral (
      select tp.price from public.ticket_prices tp
       where tp.company_id = v_company and tp.route_id = v_route
         and tp.from_pos = v_from_pos and tp.to_pos = v_to_pos
         and tp.seat_class is null and tp.active
       order by tp.created_at desc limit 1
    ) base_fare on true
   where cell.layout_id = v_layout and cell.kind = 'seat' and not cell.blocked and not cell.unusable
   order by cell.label;
end
$$;
revoke all on function public.public_trip_seats(uuid, uuid, uuid) from public;
grant execute on function public.public_trip_seats(uuid, uuid, uuid) to anon, authenticated;

create function public.public_trip_live_position(p_trip uuid)
returns table (
  trip_id uuid, company_name text, service_code text, route_name text, route_path jsonb,
  scheduled_departure timestamptz, latitude double precision, longitude double precision,
  accuracy_m real, heading real, location_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select t.id, c.name, s.code, r.name, r.path, t.scheduled_departure,
         live.latitude, live.longitude, live.accuracy_m, live.heading, live.recorded_at
    from public.trips t
    join public.companies c on c.id = t.company_id
    join public.services s on s.id = t.service_id
    join public.service_departures d on d.id = t.departure_id
    join public.routes r on r.id = d.route_id
    join public.trip_live_positions live on live.trip_id = t.id
   where t.id = p_trip and t.status = 'in_progress' and c.active
     and live.recorded_at > now() - interval '90 seconds'
$$;
revoke all on function public.public_trip_live_position(uuid) from public;
grant execute on function public.public_trip_live_position(uuid) to anon, authenticated;

notify pgrst, 'reload schema';
