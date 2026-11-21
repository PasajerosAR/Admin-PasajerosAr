-- Viajes en curso visibles en la web hasta que termina el servicio.
-- * Cada parada se vende hasta 5 minutos antes de que la unidad pase por ella (hora de la parada = salida + minutos + espera).
-- * Un viaje en curso sigue en la busqueda hasta que el conductor lo finaliza o hasta 15 minutos despues de la llegada
--   programada a la ultima parada. Las paradas ya pasadas se muestran como "en viaje": solo seguimiento, sin compra.
-- * La hora que muestra la busqueda es la de la parada de subida.

-- hora programada de salida de una parada (salida del viaje + minutos desde el inicio + espera)
create or replace function public._stop_departure(p_service uuid, p_sched timestamptz, p_stop uuid)
returns timestamptz language sql stable set search_path = public as $$
  select p_sched + make_interval(mins => coalesce((select ss.minutes_from_start + coalesce(ss.dwell_minutes, 0)
    from public.service_stops ss where ss.service_id = p_service and ss.route_stop_id = p_stop), 0))
$$;
-- limite de visibilidad de un viaje en curso: llegada programada a la ultima parada + 15 minutos (null = sin dato)
create or replace function public._trip_end_cutoff(p_service uuid, p_route uuid, p_sched timestamptz)
returns timestamptz language sql stable set search_path = public as $$
  select p_sched + make_interval(mins => max(ss.minutes_from_start) + 15)
    from public.service_stops ss join public.route_stops rs on rs.id = ss.route_stop_id
   where ss.service_id = p_service and rs.route_id = p_route
$$;

drop function if exists public.public_search_trips(uuid, uuid, date, uuid);
drop function if exists public.public_company_trips(uuid, uuid, uuid, date, integer, integer);
drop function if exists public._public_search_trips_impl(uuid, uuid, date, uuid);
drop function if exists public._public_company_trips_impl(uuid, uuid, uuid, date, integer, integer);

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
             and ticket_price.active
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
         and ticket_price.active
       where fare_from.route_id = route.id
         and fare_from.place_id = p_from_place
         and fare_to.place_id = p_to_place
    ) fare on true
   where trip.service_date = p_date
     and trip.published_at is not null
     and (
       (trip.status = 'scheduled' and segment.segment_departure > now() + interval '5 minutes')
       or (trip.status = 'in_progress'
           and coalesce(public._trip_end_cutoff(trip.service_id, route.id, trip.scheduled_departure), 'infinity'::timestamptz) > now())
     )
     and public.day_type_of(trip.service_date) = any (departure.day_types)
     and (coalesce(capacity.seats, 0) > coalesce(reserved.count, 0)
          or (trip.status = 'in_progress' and segment.segment_departure <= now() + interval '5 minutes'))
     and (p_company is null or trip.company_id = p_company)
   order by segment.segment_departure, company.name;
end
$function$;;
create or replace function public._public_company_trips_impl(
  p_company uuid,
  p_from_place uuid default null,
  p_to_place uuid default null,
  p_date date default null,
  p_page integer default 1,
  p_page_size integer default 10
)
returns table (
  trip_id uuid, company_name text, service_code text, route_name text,
  service_date date, scheduled_departure timestamptz, from_stop_id uuid,
  from_stop_name text, to_stop_id uuid, to_stop_name text, price numeric,
  available_seats int, origin_place_id uuid, destination_place_id uuid,
  total_count bigint, in_transit boolean
)
language plpgsql stable security definer set search_path = public as $$
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
             and ticket_price.active
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
         and ticket_price.active
    ) fare on true
   where trip.company_id = p_company
     and trip.service_date between v_today and v_today + 180
     and (p_date is null or trip.service_date = p_date)
     and trip.published_at is not null
     and (
       (trip.status = 'scheduled' and segment.segment_departure > now() + interval '5 minutes')
       or (trip.status = 'in_progress'
           and coalesce(public._trip_end_cutoff(trip.service_id, route.id, trip.scheduled_departure), 'infinity'::timestamptz) > now())
     )
     and public.day_type_of(trip.service_date) = any (departure.day_types)
     and (coalesce(capacity.seats, 0) > coalesce(reserved.count, 0)
          or (trip.status = 'in_progress' and segment.segment_departure <= now() + interval '5 minutes'))
   order by segment.segment_departure, route.name, service.code
   limit p_page_size
  offset (p_page - 1) * p_page_size;
end
$$;

create function public.public_search_trips(
  p_from_place uuid, p_to_place uuid, p_date date, p_company uuid default null
)
returns table (
  trip_id uuid, company_name text, service_code text, route_name text,
  service_date date, scheduled_departure timestamptz, from_stop_id uuid,
  from_stop_name text, to_stop_id uuid, to_stop_name text, price numeric,
  available_seats int, in_transit boolean
)
language sql stable security definer set search_path = public as $$
  select found.* from public._public_search_trips_impl(p_from_place, p_to_place, p_date, p_company) found
   where public.trip_feature_enabled(found.trip_id, 'web');
$$;
revoke all on function public._public_search_trips_impl(uuid, uuid, date, uuid) from public, anon, authenticated;
revoke all on function public.public_search_trips(uuid, uuid, date, uuid) from public, anon, authenticated;
grant execute on function public.public_search_trips(uuid, uuid, date, uuid) to anon, authenticated;

create function public.public_company_trips(
  p_company uuid,
  p_from_place uuid default null,
  p_to_place uuid default null,
  p_date date default null,
  p_page integer default 1,
  p_page_size integer default 10
)
returns table (
  trip_id uuid, company_name text, service_code text, route_name text,
  service_date date, scheduled_departure timestamptz, from_stop_id uuid,
  from_stop_name text, to_stop_id uuid, to_stop_name text, price numeric,
  available_seats int, origin_place_id uuid, destination_place_id uuid,
  total_count bigint, in_transit boolean
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.company_feature_enabled(p_company, 'web') then
    return;
  end if;
  return query select * from public._public_company_trips_impl(p_company, p_from_place, p_to_place, p_date, p_page, p_page_size);
end;
$$;
revoke all on function public._public_company_trips_impl(uuid, uuid, uuid, date, integer, integer) from public, anon, authenticated;
revoke all on function public.public_company_trips(uuid, uuid, uuid, date, integer, integer) from public, anon, authenticated;
grant execute on function public.public_company_trips(uuid, uuid, uuid, date, integer, integer) to anon, authenticated;

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
       order by ticket_price.created_at desc
       limit 1
    ) class_fare on true
    left join lateral (
      select ticket_price.price
        from public.ticket_prices ticket_price
       where ticket_price.company_id = v_company and ticket_price.route_id = v_route
         and ticket_price.from_pos = v_from_pos and ticket_price.to_pos = v_to_pos
         and ticket_price.seat_class is null and ticket_price.active
       order by ticket_price.created_at desc
       limit 1
    ) base_fare on true
   where cell.layout_id = v_layout
   order by cell.floor, cell.row_idx, cell.col_idx;
end
$function$;

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
       and from_pos = v_from_pos and to_pos = v_to_pos and active
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

notify pgrst, 'reload schema';
-- Seguimiento de un viaje para la web: posicion, recorrido completo y hora estimada de llegada a cada parada.
-- Publico: mientras el viaje se ve en la busqueda (ver 0048).
-- Pasajero con pasaje (sesion iniciada): desde que el viaje esta publicado hasta que se finaliza.
-- Antes de la salida programada la posicion solo se ve en la parada 1 (200 m) desde 15 minutos antes.
-- La hora estimada corrige el horario programado con el atraso o adelanto real de la unidad.
create or replace function public.trip_tracking(p_trip uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_trip public.trips;
  v_route uuid;
  v_public boolean;
  v_mine jsonb;
  v_pos record;
  v_has_pos boolean := false;
  v_k int;
  v_t double precision;
  v_dist double precision;
  v_ma int;
  v_mb int;
  v_first int;
  v_delay interval := interval '0';
  v_stops jsonb;
  v_head record;
begin
  select * into v_trip from public.trips
   where id = p_trip and status in ('scheduled', 'in_progress') and published_at is not null;
  if not found then return null; end if;
  if not exists (select 1 from public.companies where id = v_trip.company_id and active) then return null; end if;
  if not public.company_feature_enabled(v_trip.company_id, 'gps') then return null; end if;

  -- publico: mientras el viaje se ve en la busqueda (programado hasta 5 min antes; en curso hasta el fin del servicio)
  select d.route_id into v_route from public.service_departures d where d.id = v_trip.departure_id;
  v_public := public.company_feature_enabled(v_trip.company_id, 'web')
              and (case when v_trip.status = 'scheduled' then v_trip.scheduled_departure > now() + interval '5 minutes'
                        else coalesce(public._trip_end_cutoff(v_trip.service_id, v_route, v_trip.scheduled_departure), 'infinity'::timestamptz) > now() end);
  select coalesce(jsonb_agg(jsonb_build_object('from_stop_id', k.from_stop_id, 'to_stop_id', k.to_stop_id)), '[]'::jsonb)
    into v_mine
    from public.sale_tickets k
   where k.trip_id = p_trip and k.passenger_user_id = auth.uid() and k.status <> 'cancelled';
  if not (v_public or jsonb_array_length(v_mine) > 0) then return null; end if;

  select d.route_id into v_route from public.service_departures d where d.id = v_trip.departure_id;

  select l.latitude, l.longitude, l.accuracy_m, l.heading, l.recorded_at into v_pos
    from public.trip_live_positions l
   where l.trip_id = p_trip and l.recorded_at > now() - interval '90 seconds';
  v_has_pos := found and v_trip.status = 'in_progress';
  if v_has_pos then
    -- antes de la salida programada la posicion solo se muestra si la unidad esta a 200 m o menos
    -- de la parada 1 y faltan 15 minutos o menos; asi un inicio por error no se ve en la web.
    if v_has_pos and now() < v_trip.scheduled_departure then
      select coalesce(now() >= v_trip.scheduled_departure - interval '15 minutes'
             and sqrt(power((v_pos.longitude - rs.lng::double precision) * cos(radians(rs.lat::double precision)) * 111320, 2)
                    + power((v_pos.latitude - rs.lat::double precision) * 110540, 2)) <= 200, false)
        into v_has_pos
        from public.route_stops rs where rs.route_id = v_route order by rs.position limit 1;
    end if;
  end if;

  select min(position) into v_first from public.route_stops where route_id = v_route;

  if v_has_pos then
    with s as (
      select rs.position, rs.lat::double precision as lat, rs.lng::double precision as lng, ss.minutes_from_start as m
        from public.route_stops rs
        left join public.service_stops ss on ss.service_id = v_trip.service_id and ss.route_stop_id = rs.id
       where rs.route_id = v_route
    )
    select best.k, best.t, best.dist, best.ma, best.mb into v_k, v_t, v_dist, v_ma, v_mb
      from (
        select a.position as k, a.m as ma, b.m as mb, tt.t,
               sqrt(power(q.px - tt.t * q.dx, 2) + power(q.py - tt.t * q.dy, 2)) as dist
          from s a
          join s b on b.position = (select min(x.position) from s x where x.position > a.position)
          cross join lateral (select cos(radians(a.lat)) * 111320 as kx) c
          cross join lateral (select (v_pos.longitude - a.lng) * c.kx as px, (v_pos.latitude - a.lat) * 110540 as py,
                                     (b.lng - a.lng) * c.kx as dx, (b.lat - a.lat) * 110540 as dy) q
          cross join lateral (select least(1, greatest(0, coalesce((q.px * q.dx + q.py * q.dy) / nullif(q.dx * q.dx + q.dy * q.dy, 0), 0))) as t) tt
         where a.lat is not null and a.lng is not null and b.lat is not null and b.lng is not null
           and a.m is not null and b.m is not null
         order by dist
         limit 1
      ) best;
    if v_k is not null and v_dist <= 2000 then
      v_delay := now() - (v_trip.scheduled_departure + (v_ma + v_t * (v_mb - v_ma)) * interval '1 minute');
      -- esperando en el origen: no se adelanta antes de la hora de salida
      if v_k = v_first and v_t < 0.05 then v_delay := greatest(v_delay, interval '0'); end if;
    else
      v_k := null;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'name', x.name, 'place_name', x.place_name, 'position', x.position, 'lat', x.lat, 'lng', x.lng,
           'scheduled_at', x.sched,
           'passed', x.passed,
           'eta_at', case when x.passed or x.sched is null then null else greatest(x.sched + v_delay, now()) end
         ) order by x.position), '[]'::jsonb)
    into v_stops
    from (
      select rs.id, rs.name, pl.name as place_name, rs.position, rs.lat, rs.lng,
             v_trip.scheduled_departure + ss.minutes_from_start * interval '1 minute' as sched,
             (v_k is not null and (rs.position < v_k or (rs.position = v_k and v_t > 0.05))) as passed
        from public.route_stops rs
        left join public.service_stops ss on ss.service_id = v_trip.service_id and ss.route_stop_id = rs.id
        left join public.places pl on pl.id = rs.place_id
       where rs.route_id = v_route
    ) x;

  select c.name as company_name, s.code as service_code, r.name as route_name, r.path as route_path
    into v_head
    from public.companies c, public.services s, public.routes r
   where c.id = v_trip.company_id and s.id = v_trip.service_id and r.id = v_route;

  return jsonb_build_object(
    'trip_id', p_trip,
    'company_name', v_head.company_name, 'service_code', v_head.service_code, 'route_name', v_head.route_name,
    'route_path', v_head.route_path,
    'status', v_trip.status,
    'scheduled_departure', v_trip.scheduled_departure,
    'origin_name', (select name from public.route_stops where route_id = v_route order by position limit 1),
    'destination_name', (select name from public.route_stops where route_id = v_route order by position desc limit 1),
    'origin_place', (select pl.name from public.route_stops rs join public.places pl on pl.id = rs.place_id where rs.route_id = v_route order by rs.position limit 1),
    'destination_place', (select pl.name from public.route_stops rs join public.places pl on pl.id = rs.place_id where rs.route_id = v_route order by rs.position desc limit 1),
    'signal', v_has_pos,
    'position', case when v_has_pos then jsonb_build_object('latitude', v_pos.latitude, 'longitude', v_pos.longitude,
      'accuracy_m', v_pos.accuracy_m, 'heading', v_pos.heading, 'recorded_at', v_pos.recorded_at) end,
    'delay_minutes', case when v_has_pos and v_k is not null then round(extract(epoch from v_delay) / 60)::int end,
    'stops', v_stops,
    'my_stops', v_mine,
    'server_time', now()
  );
end $$;
revoke all on function public.trip_tracking(uuid) from public;
grant execute on function public.trip_tracking(uuid) to anon, authenticated;
notify pgrst, 'reload schema';
