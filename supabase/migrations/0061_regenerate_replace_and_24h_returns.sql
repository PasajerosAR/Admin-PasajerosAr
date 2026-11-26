-- 0061: (1) regenerar un dia reemplaza los viajes de otro tipo; (2) la web busca por el tipo de dia
-- con que se genero el viaje (un martes generado como feriado se ve como feriado);
-- (3) devolucion de abonos: minimo 24 h de anticipacion (antes 2 h).

-- (1) generar viajes: si el dia ya tiene viajes de OTRO tipo, hay que confirmar el reemplazo.
-- Se pueden reemplazar solo los viajes programados, sin conductor, sin ventas ni registros asociados.
create or replace function public._trips_other_type(p_date date, p_type text, p_company uuid)
returns table (id uuid, replaceable boolean, day_type text)
language sql stable security definer set search_path = public as $$
  select t.id,
         (t.status = 'scheduled' and t.driver_id is null
          and not exists (select 1 from public.sale_tickets x where x.trip_id = t.id)
          and not exists (select 1 from public.sales x where x.trip_id = t.id)
          and not exists (select 1 from public.tickets x where x.trip_id = t.id)
          and not exists (select 1 from public.passenger_checkout_orders x where x.trip_id = t.id)
          and not exists (select 1 from public.passenger_checkout_order_tickets x where x.trip_id = t.id)
          and not exists (select 1 from public.passenger_counts x where x.trip_id = t.id)
          and not exists (select 1 from public.incidents x where x.trip_id = t.id)
          and not exists (select 1 from public.ticket_boarding_events x where x.trip_id = t.id)),
         t.day_type
    from public.trips t
   where t.company_id = p_company and t.service_date = p_date
     and t.day_type <> p_type and t.status <> 'cancelled';
$$;
revoke all on function public._trips_other_type(date, text, uuid) from public, anon, authenticated;

create or replace function public.generate_trips_preview(p_date date, p_day_type text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_type text := coalesce(p_day_type, public.day_type_of(p_date));
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  return jsonb_build_object(
    'other_type', (select count(*) from public._trips_other_type(p_date, v_type, public.current_company_id())),
    'blocked', (select count(*) from public._trips_other_type(p_date, v_type, public.current_company_id()) where not replaceable),
    'types', coalesce((select jsonb_agg(distinct day_type) from public._trips_other_type(p_date, v_type, public.current_company_id())), '[]'::jsonb));
end $$;
grant execute on function public.generate_trips_preview(date, text) to authenticated;

drop function if exists public.generate_trips(date, text);
create or replace function public.generate_trips(p_date date, p_day_type text default null, p_replace boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_type    text := coalesce(p_day_type, public.day_type_of(p_date));
  v_other   int;
  v_blocked int;
  v_n int;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if v_type not in ('weekday','saturday','sunday','holiday') then raise exception 'DAY_TYPE_INVALID: tipo de dia invalido'; end if;
  select count(*), count(*) filter (where not replaceable) into v_other, v_blocked
    from public._trips_other_type(p_date, v_type, v_company);
  if v_other > 0 then
    if v_blocked > 0 then
      raise exception 'TRIPS_BLOCKED: hay % viajes de otro tipo de dia con ventas, conductor o ya iniciados; no se pueden reemplazar', v_blocked;
    end if;
    if not p_replace then
      raise exception 'REPLACE_REQUIRED: el dia ya tiene % viajes de otro tipo de dia', v_other;
    end if;
    delete from public.trips where id in (select id from public._trips_other_type(p_date, v_type, v_company));
  end if;
  -- los viajes generados quedan como borrador (published_at null) hasta que se usa publish_trips
  insert into public.trips (company_id, service_id, departure_id, service_date, scheduled_departure, day_type, published_at)
  select d.company_id, d.service_id, d.id, p_date, public.departure_ts(p_date, d.departure_time, d.next_day), v_type, null
  from public.service_departures d
  join public.services s on s.id = d.service_id
  where d.company_id = v_company and s.active and d.active and v_type = any (d.day_types)
  on conflict (departure_id, service_date) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
grant execute on function public.generate_trips(date, text, boolean) to authenticated;

-- (3) devolucion de abonos: 24 h
create or replace function public._pass_return_on_cancel() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_departure timestamptz;
begin
  if new.pass_id is null or new.status <> 'cancelled' or old.status = 'cancelled' then return new; end if;
  select scheduled_departure into v_departure from public.trips where id = new.trip_id;
  if v_departure is not null and clock_timestamp() <= v_departure - interval '24 hours' then
    update public.passes set trips_left = least(trips_total, trips_left + 1) where id = new.pass_id;
    insert into public.pass_movements (pass_id, kind, delta, ticket_id) values (new.pass_id, 'refund', 1, new.id);
  else
    insert into public.pass_movements (pass_id, kind, delta, ticket_id) values (new.pass_id, 'forfeit', 0, new.id);
  end if;
  return new;
end $$;

create or replace function public.pass_cancel_ticket(p_ticket uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_dni text;
  v_ticket public.sale_tickets;
  v_trip public.trips;
begin
  select dni into v_dni from public.passenger_profiles where user_id = auth.uid();
  if v_dni is null then raise exception 'PASSENGER_PROFILE_REQUIRED'; end if;
  select t.* into v_ticket from public.sale_tickets t
    join public.passes p on p.id = t.pass_id and p.holder_dni = v_dni
   where t.id = p_ticket for update of t;
  if not found then raise exception 'TICKET_NOT_FOUND'; end if;
  if v_ticket.status = 'cancelled' then raise exception 'ALREADY_CANCELLED'; end if;
  if v_ticket.status = 'boarded' then raise exception 'ALREADY_BOARDED'; end if;
  select * into v_trip from public.trips where id = v_ticket.trip_id;
  if v_trip.status <> 'scheduled' then raise exception 'TRIP_CLOSED'; end if;
  update public.sale_tickets set status = 'cancelled', cancelled_at = clock_timestamp(), cancel_reason = 'Cancelado por el pasajero'
   where id = v_ticket.id;
  update public.sales set status = 'refunded', refunded_at = clock_timestamp() where id = v_ticket.sale_id;
  return jsonb_build_object('ok', true, 'returned', clock_timestamp() <= v_trip.scheduled_departure - interval '24 hours');
end $$;

-- (2) busqueda web por el tipo de dia del viaje
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
             and ticket_price.active and ticket_price.day_type = trip.day_type
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
         and ticket_price.active and ticket_price.day_type = trip.day_type
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
             and ticket_price.active and ticket_price.day_type = trip.day_type
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
         and ticket_price.active and ticket_price.day_type = trip.day_type
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

