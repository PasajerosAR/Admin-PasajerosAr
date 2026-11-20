-- La web de venta sigue mostrando un viaje aunque el servicio ya haya sido iniciado por el conductor:
-- se vende hasta 5 minutos antes de la hora de salida (antes: solo viajes 'scheduled' hasta la hora exacta).

CREATE OR REPLACE FUNCTION public._public_search_trips_impl(p_from_place uuid, p_to_place uuid, p_date date, p_company uuid DEFAULT NULL::uuid)
 RETURNS TABLE(trip_id uuid, company_name text, service_code text, route_name text, service_date date, scheduled_departure timestamp with time zone, from_stop_id uuid, from_stop_name text, to_stop_id uuid, to_stop_name text, price numeric, available_seats integer)
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
         trip.service_date, trip.scheduled_departure,
         segment.from_stop_id, from_place.name, segment.to_stop_id, to_place.name,
         fare.price,
         greatest(coalesce(capacity.seats, 0) - coalesce(reserved.count, 0), 0)::int
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
             to_stop.id as to_stop_id, to_stop.position as to_position
        from public.route_stops from_stop
        join public.route_stops to_stop
          on to_stop.route_id = from_stop.route_id
         and to_stop.place_id = p_to_place
         and from_stop.position < to_stop.position
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
     and trip.status in ('scheduled', 'in_progress') and trip.published_at is not null
     and trip.scheduled_departure > now() + interval '5 minutes'
     and public.day_type_of(trip.service_date) = any (departure.day_types)
     and coalesce(capacity.seats, 0) > coalesce(reserved.count, 0)
     and (p_company is null or trip.company_id = p_company)
   order by trip.scheduled_departure, company.name;
end
$function$;

-- Parte de la versión de 0040 (salidas intermedias); agrega: viajes en curso visibles y corte 5 min antes de la salida de esa parada.
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
  total_count bigint
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
         segment.from_place_id, segment.to_place_id, count(*) over ()
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
     and trip.status in ('scheduled', 'in_progress') and trip.published_at is not null
     and segment.segment_departure > now() + interval '5 minutes'
     and public.day_type_of(trip.service_date) = any (departure.day_types)
     and coalesce(capacity.seats, 0) > coalesce(reserved.count, 0)
   order by segment.segment_departure, route.name, service.code
   limit p_page_size
  offset (p_page - 1) * p_page_size;
end
$$;

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
     and trip.scheduled_departure > now() + interval '5 minutes';
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
   where id = p_trip and status in ('scheduled', 'in_progress') and scheduled_departure > clock_timestamp() + interval '5 minutes'
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
