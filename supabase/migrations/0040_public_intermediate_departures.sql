-- Permite publicar salidas independientes desde paradas intermedias; su hora deriva del horario base y los minutos del recorrido.
alter table public.service_stops
  add column publish_from_web boolean not null default false;

create or replace function public.save_service_web_departures(
  p_service uuid, p_route uuid, p_stop_ids uuid[] default '{}'::uuid[]
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_selected uuid[] := coalesce(p_stop_ids, '{}'::uuid[]);
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.services where id = p_service and company_id = v_company)
     or not exists (select 1 from public.service_departures where service_id = p_service and route_id = p_route and company_id = v_company) then
    raise exception 'SERVICE_ROUTE_INVALID';
  end if;
  if exists (
    select 1 from unnest(v_selected) selected(stop_id)
     where not exists (
       select 1 from public.route_stops chosen
        where chosen.id = selected.stop_id and chosen.route_id = p_route
          and chosen.position > (select min(first_stop.position) from public.route_stops first_stop where first_stop.route_id = p_route)
          and chosen.position < (select max(last_stop.position) from public.route_stops last_stop where last_stop.route_id = p_route)
          and exists (select 1 from public.service_stops ss where ss.service_id = p_service and ss.route_stop_id = chosen.id)
     )
  ) then raise exception 'INTERMEDIATE_STOP_INVALID'; end if;

  update public.service_stops ss
     set publish_from_web = ss.route_stop_id = any(v_selected)
    from public.route_stops stop
   where ss.service_id = p_service and stop.id = ss.route_stop_id and stop.route_id = p_route
     and stop.position > (select min(first_stop.position) from public.route_stops first_stop where first_stop.route_id = p_route)
     and stop.position < (select max(last_stop.position) from public.route_stops last_stop where last_stop.route_id = p_route);
end
$$;
revoke all on function public.save_service_web_departures(uuid, uuid, uuid[]) from public, anon;
grant execute on function public.save_service_web_departures(uuid, uuid, uuid[]) to authenticated;

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
     and trip.status = 'scheduled' and trip.published_at is not null
     and segment.segment_departure > now()
     and public.day_type_of(trip.service_date) = any (departure.day_types)
     and coalesce(capacity.seats, 0) > coalesce(reserved.count, 0)
   order by segment.segment_departure, route.name, service.code
   limit p_page_size
  offset (p_page - 1) * p_page_size;
end
$$;
