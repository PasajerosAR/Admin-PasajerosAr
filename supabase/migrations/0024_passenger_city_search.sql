create or replace function public.passenger_places()
returns table (place_id uuid, place_name text, province text)
language sql stable security definer set search_path = public as $$
  select distinct place.id, place.name, place.province
    from public.places place
   where exists (
     select 1
       from public.route_stops stop
       join public.routes route on route.id = stop.route_id and route.active
       join public.companies company on company.id = route.company_id and company.active
       join public.service_departures departure on departure.route_id = route.id and departure.active
       join public.services service on service.id = departure.service_id and service.active
      where stop.place_id = place.id
        and exists (
          select 1 from public.route_stops other_stop
           where other_stop.route_id = stop.route_id
             and other_stop.place_id is not null
             and other_stop.place_id <> place.id
        )
   )
   order by place.name
$$;
revoke all on function public.passenger_places() from public;
grant execute on function public.passenger_places() to anon, authenticated;

drop function public.public_search_trips(uuid, uuid, date);
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
          select hold.seat_label
            from public.passenger_checkout_orders hold
            join public.route_stops held_from on held_from.id = hold.from_stop_id
            join public.route_stops held_to on held_to.id = hold.to_stop_id
           where hold.trip_id = trip.id and hold.status = 'pending'
             and hold.expires_at > now()
             and held_from.position < segment.to_position
             and held_to.position > segment.from_position
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
     and trip.status = 'scheduled'
     and trip.scheduled_departure > now()
     and public.day_type_of(trip.service_date) = any (departure.day_types)
     and coalesce(capacity.seats, 0) > coalesce(reserved.count, 0)
   order by trip.scheduled_departure, company.name;
end
$$;
revoke all on function public.public_search_trips(uuid, uuid, date) from public;
grant execute on function public.public_search_trips(uuid, uuid, date) to anon, authenticated;

create function public.public_trip_city_stops(p_trip uuid, p_from_place uuid, p_to_place uuid)
returns table (
  stop_id uuid, stop_name text, stop_position int, place_id uuid, minutes_from_start int
)
language sql stable security definer set search_path = public as $$
  select stop.id, stop.name, stop.position, stop.place_id,
         coalesce(service_stop.minutes_from_start, 0)
    from public.trips trip
    join public.service_departures departure on departure.id = trip.departure_id
    join public.route_stops stop on stop.route_id = departure.route_id
    left join public.service_stops service_stop
      on service_stop.service_id = trip.service_id and service_stop.route_stop_id = stop.id
   where trip.id = p_trip
     and p_from_place is not null and p_to_place is not null
     and p_from_place <> p_to_place
     and (
       (stop.place_id = p_from_place and exists (
         select 1 from public.route_stops destination
          where destination.route_id = stop.route_id
            and destination.place_id = p_to_place
            and destination.position > stop.position
       ))
       or
       (stop.place_id = p_to_place and exists (
         select 1 from public.route_stops origin
          where origin.route_id = stop.route_id
            and origin.place_id = p_from_place
            and origin.position < stop.position
       ))
     )
   order by stop.position
$$;
revoke all on function public.public_trip_city_stops(uuid, uuid, uuid) from public;
grant execute on function public.public_trip_city_stops(uuid, uuid, uuid) to anon, authenticated;

drop function public.public_trip_seats(uuid, uuid, uuid);
create function public.public_trip_seats(
  p_trip uuid, p_from_stop uuid, p_to_stop uuid
) returns table (
  cell_id uuid, floor int, row_idx int, col_idx int, seat_label text,
  seat_class text, available boolean, price numeric, cell_kind text
)
language plpgsql stable security definer set search_path = public as $$
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
     and trip.status = 'scheduled'
     and trip.scheduled_departure > now();
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
             select 1
               from public.sale_tickets ticket
               join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
               join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
              where ticket.trip_id = p_trip and ticket.seat_label = cell.label
                and ticket.status in ('valid', 'boarded')
                and booked_from.position < v_to_pos and booked_to.position > v_from_pos
           ) and not exists (
             select 1
               from public.passenger_checkout_orders hold
               join public.route_stops held_from on held_from.id = hold.from_stop_id
               join public.route_stops held_to on held_to.id = hold.to_stop_id
              where hold.trip_id = p_trip and hold.seat_label = cell.label
                and hold.status = 'pending' and hold.expires_at > now()
                and held_from.position < v_to_pos and held_to.position > v_from_pos
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
         and lower(trim(ticket_price.seat_class)) = lower(trim(cell.seat_class))
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
$$;
revoke all on function public.public_trip_seats(uuid, uuid, uuid) from public;
grant execute on function public.public_trip_seats(uuid, uuid, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
