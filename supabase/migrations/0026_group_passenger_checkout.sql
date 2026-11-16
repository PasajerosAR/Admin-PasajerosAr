create table public.passenger_checkout_order_tickets (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.passenger_checkout_orders (id) on delete cascade,
  trip_id uuid not null references public.trips (id),
  from_stop_id uuid not null references public.route_stops (id),
  to_stop_id uuid not null references public.route_stops (id),
  layout_cell_id uuid not null references public.layout_cells (id),
  seat_label text not null,
  passenger_name text not null,
  passenger_dni text not null,
  passenger_email text not null,
  passenger_phone text not null,
  price numeric(10, 2) not null check (price > 0),
  created_at timestamptz not null default now(),
  unique (order_id, layout_cell_id)
);
create index passenger_checkout_order_tickets_trip_seat_idx
  on public.passenger_checkout_order_tickets (trip_id, seat_label);
alter table public.passenger_checkout_order_tickets enable row level security;
revoke all on public.passenger_checkout_order_tickets from public, anon, authenticated;
grant all on public.passenger_checkout_order_tickets to service_role;

drop function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, uuid, text);
create function public.begin_passenger_checkout(
  p_user uuid, p_trip uuid, p_from_stop uuid, p_to_stop uuid, p_tickets jsonb, p_phone text
) returns jsonb
language plpgsql security definer set search_path = public as $$
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
   where id = p_trip and status = 'scheduled' and scheduled_departure > clock_timestamp()
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
$$;
revoke all on function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, jsonb, text)
  to service_role;

create or replace function public.reject_ticket_for_held_seat()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_route_id uuid;
  v_from_pos int;
  v_to_pos int;
  v_channel text;
begin
  if new.seat_label is null then return new; end if;
  select channel into v_channel from public.sales where id = new.sale_id;
  if v_channel = 'web' then return new; end if;

  select route_id into v_route_id from public.service_departures
   where id = (select departure_id from public.trips where id = new.trip_id);
  select position into v_from_pos from public.route_stops
   where id = new.from_stop_id and route_id = v_route_id;
  select position into v_to_pos from public.route_stops
   where id = new.to_stop_id and route_id = v_route_id;
  if exists (
    select 1 from public.passenger_checkout_order_tickets held_ticket
      join public.passenger_checkout_orders held_order on held_order.id = held_ticket.order_id
      join public.route_stops held_from on held_from.id = held_ticket.from_stop_id
      join public.route_stops held_to on held_to.id = held_ticket.to_stop_id
     where held_ticket.trip_id = new.trip_id and held_ticket.seat_label = new.seat_label
       and held_order.status = 'pending' and held_order.expires_at > clock_timestamp()
       and held_from.position < v_to_pos and held_to.position > v_from_pos
  ) or exists (
    select 1 from public.passenger_checkout_orders held_order
      join public.route_stops held_from on held_from.id = held_order.from_stop_id
      join public.route_stops held_to on held_to.id = held_order.to_stop_id
     where held_order.trip_id = new.trip_id and held_order.seat_label = new.seat_label
       and held_order.status = 'pending' and held_order.expires_at > clock_timestamp()
       and held_from.position < v_to_pos and held_to.position > v_from_pos
       and not exists (
         select 1 from public.passenger_checkout_order_tickets held_ticket
          where held_ticket.order_id = held_order.id
       )
  ) then
    raise exception 'SEAT_RESERVED: el asiento está reservado durante un pago web';
  end if;
  return new;
end
$$;
revoke all on function public.reject_ticket_for_held_seat() from public, anon, authenticated;

create or replace function public.finalize_passenger_checkout(
  p_order uuid, p_payment_id text, p_amount numeric, p_currency text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_order public.passenger_checkout_orders;
  v_trip public.trips;
  v_route_id uuid;
  v_from_pos int;
  v_to_pos int;
  v_sale_id uuid;
  v_ticket_id uuid;
  v_qr text;
  v_item record;
  v_ticket_ids jsonb := '[]'::jsonb;
begin
  if auth.role() <> 'service_role' then raise exception 'FORBIDDEN'; end if;
  select * into v_order from public.passenger_checkout_orders
   where id = p_order for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.status = 'approved' then
    if v_order.mp_payment_id <> p_payment_id then raise exception 'PAYMENT_ID_CONFLICT'; end if;
    return jsonb_build_object('status', 'approved', 'sale_id', v_order.sale_id);
  end if;
  if p_payment_id is null or p_amount <> v_order.price or p_currency <> 'ARS' then
    raise exception 'PAYMENT_AMOUNT_INVALID';
  end if;
  if v_order.status in ('expired', 'cancelled') then
    update public.passenger_checkout_orders
       set status = 'refund_required', mp_payment_id = p_payment_id
     where id = v_order.id;
    return jsonb_build_object('status', 'refund_required');
  end if;
  if v_order.status <> 'pending' then
    return jsonb_build_object('status', v_order.status);
  end if;

  if v_order.expires_at <= clock_timestamp() then
    update public.passenger_checkout_orders
       set status = 'refund_required', mp_payment_id = p_payment_id
     where id = v_order.id;
    return jsonb_build_object('status', 'refund_required');
  end if;

  select * into v_trip from public.trips where id = v_order.trip_id for update;
  select route_id into v_route_id from public.service_departures
   where id = v_trip.departure_id and service_id = v_trip.service_id;
  if exists (
    select 1 from public.passenger_checkout_order_tickets item
      join public.route_stops item_from on item_from.id = item.from_stop_id
      join public.route_stops item_to on item_to.id = item.to_stop_id
      join public.sale_tickets ticket on ticket.trip_id = item.trip_id
        and ticket.seat_label = item.seat_label and ticket.status in ('valid', 'boarded')
      join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
      join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
     where item.order_id = v_order.id
       and booked_from.position < item_to.position and booked_to.position > item_from.position
  ) or (
    not exists (select 1 from public.passenger_checkout_order_tickets where order_id = v_order.id)
    and exists (
      select 1 from public.sale_tickets ticket
        join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
        join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
       where ticket.trip_id = v_order.trip_id and ticket.seat_label = v_order.seat_label
         and ticket.status in ('valid', 'boarded')
         and booked_from.position < (select position from public.route_stops where id = v_order.to_stop_id)
         and booked_to.position > (select position from public.route_stops where id = v_order.from_stop_id)
    )
  ) then
    update public.passenger_checkout_orders
       set status = 'refund_required', mp_payment_id = p_payment_id
     where id = v_order.id;
    return jsonb_build_object('status', 'refund_required');
  end if;

  insert into public.sales (
    company_id, seller_id, trip_id, payment_method, mp_payment_id, total, notes, channel
  ) values (
    v_order.company_id, null, v_order.trip_id, 'mp', p_payment_id,
    v_order.price, 'Checkout web Mercado Pago', 'web'
  ) returning id into v_sale_id;

  if exists (select 1 from public.passenger_checkout_order_tickets where order_id = v_order.id) then
    for v_item in
      select * from public.passenger_checkout_order_tickets
       where order_id = v_order.id order by created_at, id
    loop
      v_qr := gen_random_uuid()::text;
      insert into public.sale_tickets (
        company_id, sale_id, trip_id, seat_label, layout_cell_id,
        from_stop_id, to_stop_id, passenger_name, passenger_dni, passenger_email,
        passenger_phone, price, qr_code, passenger_user_id, status
      ) values (
        v_order.company_id, v_sale_id, v_order.trip_id, v_item.seat_label, v_item.layout_cell_id,
        v_item.from_stop_id, v_item.to_stop_id, v_item.passenger_name, v_item.passenger_dni,
        v_item.passenger_email, v_item.passenger_phone, v_item.price, v_qr,
        v_order.passenger_user_id, 'valid'
      ) returning id into v_ticket_id;
      v_ticket_ids := v_ticket_ids || jsonb_build_array(v_ticket_id);
    end loop;
  else
    select position into v_from_pos from public.route_stops
     where id = v_order.from_stop_id and route_id = v_route_id;
    select position into v_to_pos from public.route_stops
     where id = v_order.to_stop_id and route_id = v_route_id;
    v_qr := gen_random_uuid()::text;
    insert into public.sale_tickets (
      company_id, sale_id, trip_id, seat_label, layout_cell_id,
      from_stop_id, to_stop_id, passenger_name, passenger_dni, passenger_email,
      passenger_phone, price, qr_code, passenger_user_id, status
    ) values (
      v_order.company_id, v_sale_id, v_order.trip_id, v_order.seat_label, v_order.layout_cell_id,
      v_order.from_stop_id, v_order.to_stop_id, v_order.passenger_name, v_order.passenger_dni,
      v_order.passenger_email, v_order.passenger_phone, v_order.price, v_qr,
      v_order.passenger_user_id, 'valid'
    ) returning id into v_ticket_id;
    v_ticket_ids := jsonb_build_array(v_ticket_id);
  end if;

  update public.passenger_checkout_orders
     set status = 'approved', mp_payment_id = p_payment_id, sale_id = v_sale_id
   where id = v_order.id;
  return jsonb_build_object(
    'status', 'approved', 'sale_id', v_sale_id,
    'ticket_id', v_ticket_ids ->> 0, 'ticket_ids', v_ticket_ids
  );
end
$$;
revoke all on function public.finalize_passenger_checkout(uuid, text, numeric, text)
  from public, anon, authenticated;
grant execute on function public.finalize_passenger_checkout(uuid, text, numeric, text)
  to service_role;

create or replace function public.public_search_trips(p_from_place uuid, p_to_place uuid, p_date date)
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
     and trip.status = 'scheduled'
     and trip.scheduled_departure > now()
     and public.day_type_of(trip.service_date) = any (departure.day_types)
     and coalesce(capacity.seats, 0) > coalesce(reserved.count, 0)
   order by trip.scheduled_departure, company.name;
end
$$;
revoke all on function public.public_search_trips(uuid, uuid, date) from public;
grant execute on function public.public_search_trips(uuid, uuid, date) to anon, authenticated;

create or replace function public.public_trip_seats(
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
$$;
revoke all on function public.public_trip_seats(uuid, uuid, uuid) from public;
grant execute on function public.public_trip_seats(uuid, uuid, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
