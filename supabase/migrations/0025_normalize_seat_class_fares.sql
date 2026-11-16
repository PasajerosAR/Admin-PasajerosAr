create function public.normalize_seat_class(p_class text)
returns text
language sql immutable parallel safe set search_path = public as $$
  select nullif(translate(lower(trim(p_class)), 'áéíóúüñ', 'aeiouun'), '')
$$;
revoke all on function public.normalize_seat_class(text) from public, anon, authenticated;

create or replace function public.save_ticket_price(
  p_route uuid, p_from_pos int, p_to_pos int, p_price numeric, p_seat_class text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_id uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_route is null or p_from_pos < 1 or p_to_pos <= p_from_pos or p_price is null or p_price < 0 then
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
   order by price.created_at desc
   limit 1 for update;
  if v_id is null then
    insert into public.ticket_prices (company_id, route_id, from_pos, to_pos, price, seat_class)
    values (v_company, p_route, p_from_pos, p_to_pos, p_price, nullif(trim(p_seat_class), ''))
    returning id into v_id;
  else
    update public.ticket_prices set price = p_price, active = true where id = v_id;
  end if;
  return v_id;
end
$$;
revoke all on function public.save_ticket_price(uuid, int, int, numeric, text) from public, anon;
grant execute on function public.save_ticket_price(uuid, int, int, numeric, text) to authenticated;

create or replace function public.create_sale_with_tickets(
  p_trip uuid, p_payment_method public.payment_method, p_notes text, p_passengers jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
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
$$;
revoke all on function public.create_sale_with_tickets(uuid, public.payment_method, text, jsonb) from public, anon;
grant execute on function public.create_sale_with_tickets(uuid, public.payment_method, text, jsonb) to authenticated;

create or replace function public.begin_passenger_checkout(
  p_user uuid, p_trip uuid, p_from_stop uuid, p_to_stop uuid, p_layout_cell uuid, p_phone text
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
  v_seat_label text;
  v_seat_class text;
  v_price numeric(10, 2);
  v_order_id uuid;
  v_expires_at timestamptz;
  v_from_name text;
  v_to_name text;
begin
  if auth.role() <> 'service_role' then raise exception 'FORBIDDEN'; end if;
  if p_user is null or p_trip is null or p_from_stop is null or p_to_stop is null
     or p_layout_cell is null or length(trim(coalesce(p_phone, ''))) < 7 then
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

  select label, seat_class into v_seat_label, v_seat_class
    from public.layout_cells
   where id = p_layout_cell and layout_id = v_trip.layout_id
     and kind = 'seat' and not blocked and not unusable;
  if not found or v_seat_label is null then raise exception 'SEAT_UNAVAILABLE'; end if;

  select price into v_price from public.ticket_prices
   where company_id = v_company_id and route_id = v_route_id
     and from_pos = v_from_pos and to_pos = v_to_pos and active
     and (seat_class is null or public.normalize_seat_class(seat_class)
       = public.normalize_seat_class(v_seat_class))
   order by (seat_class is not null) desc, created_at desc
   limit 1;
  if not found or v_price <= 0 then raise exception 'FARE_NOT_FOUND'; end if;

  update public.passenger_checkout_orders
     set status = 'expired'
   where trip_id = p_trip and status = 'pending' and expires_at <= clock_timestamp();

  if exists (
    select 1 from public.sale_tickets ticket
      join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
      join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
     where ticket.trip_id = p_trip and ticket.seat_label = v_seat_label
       and ticket.status in ('valid', 'boarded')
       and booked_from.position < v_to_pos and booked_to.position > v_from_pos
  ) or exists (
    select 1 from public.passenger_checkout_orders order_row
      join public.route_stops booked_from on booked_from.id = order_row.from_stop_id
      join public.route_stops booked_to on booked_to.id = order_row.to_stop_id
     where order_row.trip_id = p_trip and order_row.seat_label = v_seat_label
       and order_row.status = 'pending' and order_row.expires_at > clock_timestamp()
       and booked_from.position < v_to_pos and booked_to.position > v_from_pos
  ) then
    raise exception 'SEAT_TAKEN';
  end if;

  insert into public.passenger_checkout_orders (
    company_id, mp_connection_id, passenger_user_id, trip_id, from_stop_id, to_stop_id,
    layout_cell_id, seat_label, passenger_name, passenger_dni, passenger_email,
    passenger_phone, price
  ) values (
    v_company_id, v_company_id, p_user, p_trip, p_from_stop, p_to_stop,
    p_layout_cell, v_seat_label,
    trim(v_passenger.first_name || ' ' || v_passenger.last_name),
    v_passenger.dni, v_passenger.email, trim(p_phone), v_price
  ) returning id, expires_at into v_order_id, v_expires_at;

  return jsonb_build_object(
    'order_id', v_order_id, 'company_id', v_company_id, 'price', v_price,
    'service_code', v_service_code, 'route_name', v_route_name,
    'service_date', v_trip.service_date, 'seat_label', v_seat_label,
    'from_stop', v_from_name, 'to_stop', v_to_name, 'expires_at', v_expires_at
  );
end
$$;
revoke all on function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, uuid, text)
  to service_role;

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
