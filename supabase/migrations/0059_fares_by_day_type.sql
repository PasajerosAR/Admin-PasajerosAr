-- Tarifas por tipo de día: cada tarifa (tramo y clase) tiene un precio por día hábil, sábado, domingo y feriado.
--  * ticket_prices.day_type: una fila por tramo, clase y tipo de día. Las tarifas existentes se copian a los cuatro tipos.
--  * Un tramo sin precio para un tipo de día no se vende ese día (igual que antes cuando faltaba el precio).
--  * El precio de un viaje sale de la tarifa que corresponde al tipo de día del viaje (trips.day_type).
--  * No puede haber dos tarifas activas del mismo tramo, clase y tipo de día.
alter table public.ticket_prices add column day_type text not null default 'weekday'
  check (day_type in ('weekday', 'saturday', 'sunday', 'holiday'));
alter table public.ticket_prices drop constraint ticket_prices_company_id_route_id_from_pos_to_pos_seat_clas_key;
insert into public.ticket_prices (company_id, route_id, from_pos, to_pos, price, seat_class, active, day_type)
select p.company_id, p.route_id, p.from_pos, p.to_pos, p.price, p.seat_class, p.active, d
  from public.ticket_prices p cross join unnest(array['saturday', 'sunday', 'holiday']) d
 where p.day_type = 'weekday';
create unique index ticket_prices_active_unique
  on public.ticket_prices (company_id, route_id, from_pos, to_pos, coalesce(seat_class, ''), day_type) where active;

-- guardar tarifa (precio null = ese tipo de día no se vende)
drop function public.save_ticket_price(uuid, int, int, numeric, text);
drop function public._save_ticket_price_impl(uuid, int, int, numeric, text);
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
  if p_route is null or p_from_pos < 1 or p_to_pos <= p_from_pos or p_price < 0 or p_day_type is null or p_day_type <> all (array['weekday','saturday','sunday','holiday']) then
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

revoke all on function public._save_ticket_price_impl(uuid, int, int, numeric, text, text) from public, anon, authenticated;
create function public.save_ticket_price(p_route uuid, p_from_pos int, p_to_pos int, p_price numeric, p_seat_class text, p_day_type text)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if public.current_company_id() is not null and not public.company_feature_enabled(public.current_company_id(), 'fares') then
    raise exception 'FEATURE_BLOCKED: las tarifas y ventas no están habilitadas para esta empresa';
  end if;
  return public._save_ticket_price_impl(p_route, p_from_pos, p_to_pos, p_price, p_seat_class, p_day_type);
end;
$$;
revoke all on function public.save_ticket_price(uuid, int, int, numeric, text, text) from public, anon, authenticated;
grant execute on function public.save_ticket_price(uuid, int, int, numeric, text, text) to authenticated;

-- "Aplicar a todos" por tipo de día
drop function public.apply_price_to_all(uuid, numeric, text);
create function public.apply_price_to_all(p_route uuid, p_price numeric, p_seat_class text default null,
  p_day_types text[] default array['weekday','saturday','sunday','holiday'])
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_pair record;
  v_day text;
  v_n int := 0;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_route is null or p_price is null or p_price < 0 then raise exception 'PRICE_INVALID: revisá el precio'; end if;
  if p_day_types is null or cardinality(p_day_types) = 0 then raise exception 'PRICE_INVALID: elegí al menos un tipo de día'; end if;
  for v_pair in
    select f.position as from_pos, t.position as to_pos
      from public.route_stops f
      join public.route_stops t on t.route_id = f.route_id and t.position > f.position
     where f.route_id = p_route
       and coalesce(f.place_id::text, f.id::text) <> coalesce(t.place_id::text, t.id::text)
     order by f.position, t.position
  loop
    foreach v_day in array p_day_types loop
      perform public.save_ticket_price(p_route, v_pair.from_pos, v_pair.to_pos, p_price, p_seat_class, v_day);
    end loop;
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'ROUTE_INVALID: el recorrido no tiene tramos entre localidades distintas'; end if;
  return v_n;
end $$;
revoke all on function public.apply_price_to_all(uuid, numeric, text, text[]) from public, anon, authenticated;
grant execute on function public.apply_price_to_all(uuid, numeric, text, text[]) to authenticated;

-- lecturas de precio por tipo de día del viaje
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
       and from_pos = v_from_pos and to_pos = v_to_pos and active and day_type = v_trip.day_type
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
         and tp.day_type = (select tr.day_type from public.trips tr where tr.id = p_trip)
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
begin
  if p_payment_method not in ('cash', 'transfer', 'debit', 'credit')
     or (v_role = 'driver' and p_payment_method in ('debit', 'credit')) then
    raise exception 'PAYMENT_INVALID: forma de pago no habilitada';
  end if;
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) < 1 or jsonb_array_length(p_seats) > 20 then
    raise exception 'SALE_INVALID: elegí al menos un asiento';
  end if;
  select * into v_ctx from public._taquilla_ctx(p_trip, true);

  insert into public.sales (company_id, seller_id, trip_id, payment_method, total, notes)
  values (v_ctx.o_company, auth.uid(), p_trip, p_payment_method, 0, case when v_role = 'driver' then 'Venta en taquilla' else 'Venta en ventanilla' end)
  returning id into v_sale;

  for v_seat in select value from jsonb_array_elements(p_seats)
  loop
    select * into v_s from public._taquilla_seat(p_trip, v_ctx.o_route, v_ctx.o_layout, v_seat);
    select tp.price into v_fare from public.ticket_prices tp
     where tp.company_id = v_ctx.o_company and tp.route_id = v_ctx.o_route
       and tp.from_pos = v_s.o_from_pos and tp.to_pos = v_s.o_to_pos and tp.active
       and tp.day_type = (select tr.day_type from public.trips tr where tr.id = p_trip)
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
    v_total := v_total + v_price;
    v_tickets := v_tickets || jsonb_build_array(jsonb_build_object(
      'id', v_id, 'qr_code', v_qr, 'seat_label', v_s.o_label, 'price', v_price,
      'passenger_name', v_name, 'passenger_dni', v_dni, 'email', case when v_email = 'taquilla@pasajeros.ar' then null else v_email end,
      'from_stop_id', v_s.o_from, 'to_stop_id', v_s.o_to, 'ticket_type', v_ticket_type));
  end loop;

  update public.sales
     set total = v_total,
         payment_method = case when v_total = 0 then 'complimentary'::public.payment_method else p_payment_method end
   where id = v_sale;
  delete from public.seat_holds where trip_id = p_trip and (held_by = auth.uid() or expires_at <= clock_timestamp());
  return jsonb_build_object('sale_id', v_sale, 'tickets', v_tickets, 'total', v_total);
end $function$;

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
         and ticket_price.day_type = (select tr.day_type from public.trips tr where tr.id = p_trip)
       order by ticket_price.created_at desc
       limit 1
    ) class_fare on true
    left join lateral (
      select ticket_price.price
        from public.ticket_prices ticket_price
       where ticket_price.company_id = v_company and ticket_price.route_id = v_route
         and ticket_price.from_pos = v_from_pos and ticket_price.to_pos = v_to_pos
         and ticket_price.seat_class is null and ticket_price.active
         and ticket_price.day_type = (select tr.day_type from public.trips tr where tr.id = p_trip)
       order by ticket_price.created_at desc
       limit 1
    ) base_fare on true
   where cell.layout_id = v_layout
   order by cell.floor, cell.row_idx, cell.col_idx;
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
$function$;


-- precios por par de localidades y tipo de día para el generador de abonos
drop function public.pass_fare_pairs();
CREATE OR REPLACE FUNCTION public.pass_fare_pairs()
 RETURNS TABLE(place_a uuid, place_b uuid, place_a_name text, place_b_name text, seat_class text, base_price numeric, day_type text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  return query
    select least(fs.place_id::text, ts.place_id::text)::uuid, greatest(fs.place_id::text, ts.place_id::text)::uuid,
           (select name from public.places where id = least(fs.place_id::text, ts.place_id::text)::uuid),
           (select name from public.places where id = greatest(fs.place_id::text, ts.place_id::text)::uuid),
           tp.seat_class, max(tp.price)::numeric, tp.day_type
      from public.ticket_prices tp
      join public.route_stops fs on fs.route_id = tp.route_id and fs.position = tp.from_pos
      join public.route_stops ts on ts.route_id = tp.route_id and ts.position = tp.to_pos
     where tp.company_id = public.current_company_id() and tp.active
       and fs.place_id is not null and ts.place_id is not null and fs.place_id <> ts.place_id
     group by 1, 2, 3, 4, tp.seat_class, tp.day_type
     order by 3, 4, tp.seat_class nulls first, tp.day_type;
end $function$;

revoke all on function public.pass_fare_pairs() from public, anon;
grant execute on function public.pass_fare_pairs() to authenticated;
notify pgrst, 'reload schema';
