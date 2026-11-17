-- Taquilla (venta a bordo desde la app del conductor) como función aparte, con reserva temporal de asientos.
--
--  * la taquilla se habilita/bloquea junto con 'fares' (Tarifas, ventas y taquilla): una sola clave para todo lo que es vender.
--  * seat_holds: reserva de asientos por unos minutos mientras se cobra (taquilla_hold_minutes()).
--  * taquilla_seat_status(): estado único de asientos (vendidos, reservados en la web, reservados en taquilla).
--  * taquilla_sell(): cobra en efectivo o transferencia y emite los pasajes.
--  * la ventanilla (create_sale_with_tickets), la web (begin_passenger_checkout / public_trip_seats) respetan las reservas.

-- minutos que se mantiene reservado un asiento
create function public.taquilla_hold_minutes() returns int
language sql immutable as $$ select 5 $$;
revoke all on function public.taquilla_hold_minutes() from public, anon, authenticated;

create table public.seat_holds (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id),
  trip_id     uuid not null references public.trips (id) on delete cascade,
  seat_label  text not null,
  from_pos    int not null,
  to_pos      int not null,
  held_by     uuid not null references public.profiles (id),
  expires_at  timestamptz not null,
  created_at  timestamptz not null default now(),
  constraint seat_holds_range check (to_pos > from_pos)
);
create index seat_holds_trip_idx on public.seat_holds (trip_id, expires_at);
alter table public.seat_holds enable row level security;
revoke all on public.seat_holds from public, anon, authenticated;
grant all on public.seat_holds to service_role;

-- Tramos ocupados de un viaje por cualquier motivo.
--   kind: 'sold' (pasaje emitido), 'web' (compra pendiente en la web), 'hold' (reserva de taquilla/ventanilla)
create function public._trip_seat_ranges(p_trip uuid)
returns table (seat_label text, from_pos int, to_pos int, kind text, held_by uuid, expires_at timestamptz)
language sql stable security definer set search_path = public as $$
  select st.seat_label, fs.position, ts.position, 'sold', null::uuid, null::timestamptz
    from public.sale_tickets st
    join public.route_stops fs on fs.id = st.from_stop_id
    join public.route_stops ts on ts.id = st.to_stop_id
   where st.trip_id = p_trip and st.status in ('valid', 'boarded') and st.seat_label is not null
  union all
  select t.seat_label, fs.position, ts.position, 'web', null::uuid, o.expires_at
    from public.passenger_checkout_order_tickets t
    join public.passenger_checkout_orders o on o.id = t.order_id
    join public.route_stops fs on fs.id = t.from_stop_id
    join public.route_stops ts on ts.id = t.to_stop_id
   where t.trip_id = p_trip and o.status = 'pending' and o.expires_at > clock_timestamp()
  union all
  select o.seat_label, fs.position, ts.position, 'web', null::uuid, o.expires_at
    from public.passenger_checkout_orders o
    join public.route_stops fs on fs.id = o.from_stop_id
    join public.route_stops ts on ts.id = o.to_stop_id
   where o.trip_id = p_trip and o.status = 'pending' and o.expires_at > clock_timestamp()
     and not exists (select 1 from public.passenger_checkout_order_tickets x where x.order_id = o.id)
  union all
  select h.seat_label, h.from_pos, h.to_pos, 'hold', h.held_by, h.expires_at
    from public.seat_holds h
   where h.trip_id = p_trip and h.expires_at > clock_timestamp()
$$;
revoke all on function public._trip_seat_ranges(uuid) from public, anon, authenticated;

-- Valida el viaje y el permiso para operar la taquilla. Devuelve empresa, recorrido y disposición.
create function public._taquilla_ctx(
  p_trip uuid, p_lock boolean,
  out o_company uuid, out o_route uuid, out o_layout uuid
) language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_user_role()::text;
  v_trip public.trips;
begin
  if v_role is null or v_role not in ('driver', 'company_admin', 'seller') then raise exception 'FORBIDDEN'; end if;
  if p_lock then
    select * into v_trip from public.trips where id = p_trip and company_id = public.current_company_id() for update;
  else
    select * into v_trip from public.trips where id = p_trip and company_id = public.current_company_id();
  end if;
  if not found or (v_role = 'driver' and v_trip.driver_id is distinct from auth.uid()) then raise exception 'TRIP_NOT_FOUND'; end if;
  if not public.company_feature_enabled(v_trip.company_id, 'fares') then
    raise exception 'FEATURE_BLOCKED: las tarifas, ventas y taquilla no están habilitadas para esta empresa';
  end if;
  if v_trip.status not in ('scheduled', 'in_progress') then raise exception 'TRIP_CLOSED'; end if;
  select d.route_id into o_route from public.service_departures d
   where d.id = v_trip.departure_id and d.service_id = v_trip.service_id and d.company_id = v_trip.company_id;
  if not found then raise exception 'ROUTE_INVALID'; end if;
  o_company := v_trip.company_id;
  o_layout := v_trip.layout_id;
end $$;
revoke all on function public._taquilla_ctx(uuid, boolean) from public, anon, authenticated;

-- Valida un asiento pedido ({seat_label, from_stop_id, to_stop_id}) y que esté libre (propias reservas no cuentan).
create function public._taquilla_seat(
  p_trip uuid, p_route uuid, p_layout uuid, p_seat jsonb,
  out o_label text, out o_class text, out o_cell uuid, out o_from uuid, out o_to uuid, out o_from_pos int, out o_to_pos int
) language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(p_seat) <> 'object' then raise exception 'SEAT_INVALID'; end if;
  o_from := nullif(p_seat ->> 'from_stop_id', '')::uuid;
  o_to := nullif(p_seat ->> 'to_stop_id', '')::uuid;
  select position into o_from_pos from public.route_stops where id = o_from and route_id = p_route;
  if not found then raise exception 'STOP_INVALID: origen fuera del recorrido'; end if;
  select position into o_to_pos from public.route_stops where id = o_to and route_id = p_route;
  if not found or o_from_pos >= o_to_pos then raise exception 'STOP_INVALID: destino debe ser posterior al origen'; end if;
  if p_layout is null then raise exception 'SEAT_UNAVAILABLE: el viaje no tiene disposición asignada'; end if;
  select c.id, c.label, c.seat_class into o_cell, o_label, o_class
    from public.layout_cells c
   where c.layout_id = p_layout and c.label = nullif(trim(coalesce(p_seat ->> 'seat_label', '')), '')
     and c.kind = 'seat' and not c.blocked and not c.unusable
   limit 1;
  if not found then raise exception 'SEAT_UNAVAILABLE: asiento inexistente o bloqueado'; end if;
  if exists (
    select 1 from public._trip_seat_ranges(p_trip) r
     where r.seat_label = o_label and r.from_pos < o_to_pos and r.to_pos > o_from_pos
       and not (r.kind = 'hold' and r.held_by = auth.uid())
  ) then raise exception 'SEAT_TAKEN: el asiento ya está ocupado o reservado en parte de ese tramo'; end if;
end $$;
revoke all on function public._taquilla_seat(uuid, uuid, uuid, jsonb) from public, anon, authenticated;

-- Estado de los asientos para la pantalla de taquilla (se consulta cada pocos segundos).
create function public.taquilla_seat_status(p_trip uuid)
returns table (seat_label text, from_pos int, to_pos int, kind text, mine boolean, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform public._taquilla_ctx(p_trip, false);
  return query
  select r.seat_label, r.from_pos, r.to_pos, r.kind, (r.kind = 'hold' and r.held_by = auth.uid()), r.expires_at
    from public._trip_seat_ranges(p_trip) r;
end $$;
revoke all on function public.taquilla_seat_status(uuid) from public, anon, authenticated;
grant execute on function public.taquilla_seat_status(uuid) to authenticated;

-- Reserva los asientos elegidos (reemplaza las reservas anteriores de este usuario en el viaje). Lista vacía = liberar.
create function public.taquilla_hold_seats(p_trip uuid, p_seats jsonb)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  v_ctx record;
  v_seat jsonb;
  v_s record;
  v_expires timestamptz := clock_timestamp() + make_interval(mins => public.taquilla_hold_minutes());
begin
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) > 10 then raise exception 'SEAT_INVALID'; end if;
  select * into v_ctx from public._taquilla_ctx(p_trip, true);
  delete from public.seat_holds where trip_id = p_trip and (held_by = auth.uid() or expires_at <= clock_timestamp());
  for v_seat in select value from jsonb_array_elements(p_seats)
  loop
    select * into v_s from public._taquilla_seat(p_trip, v_ctx.o_route, v_ctx.o_layout, v_seat);
    insert into public.seat_holds (company_id, trip_id, seat_label, from_pos, to_pos, held_by, expires_at)
    values (v_ctx.o_company, p_trip, v_s.o_label, v_s.o_from_pos, v_s.o_to_pos, auth.uid(), v_expires);
  end loop;
  return case when jsonb_array_length(p_seats) = 0 then null else v_expires end;
end $$;
revoke all on function public.taquilla_hold_seats(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.taquilla_hold_seats(uuid, jsonb) to authenticated;

-- Cobro en efectivo o transferencia: emite los pasajes. Nombre y DNI de cada pasajero los carga el conductor.
create function public.taquilla_sell(p_trip uuid, p_payment_method public.payment_method, p_seats jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ctx record;
  v_seat jsonb;
  v_s record;
  v_sale uuid;
  v_price numeric(10, 2);
  v_total numeric(10, 2) := 0;
  v_name text;
  v_dni text;
  v_qr text;
  v_id uuid;
  v_tickets jsonb := '[]'::jsonb;
begin
  if p_payment_method not in ('cash', 'transfer') then raise exception 'PAYMENT_INVALID: la taquilla cobra en efectivo o transferencia'; end if;
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) < 1 or jsonb_array_length(p_seats) > 10 then
    raise exception 'SALE_INVALID: elegí al menos un asiento';
  end if;
  select * into v_ctx from public._taquilla_ctx(p_trip, true);

  insert into public.sales (company_id, seller_id, trip_id, payment_method, total, notes)
  values (v_ctx.o_company, auth.uid(), p_trip, p_payment_method, 0, 'Venta en taquilla')
  returning id into v_sale;

  for v_seat in select value from jsonb_array_elements(p_seats)
  loop
    select * into v_s from public._taquilla_seat(p_trip, v_ctx.o_route, v_ctx.o_layout, v_seat);
    select tp.price into v_price from public.ticket_prices tp
     where tp.company_id = v_ctx.o_company and tp.route_id = v_ctx.o_route
       and tp.from_pos = v_s.o_from_pos and tp.to_pos = v_s.o_to_pos and tp.active
       and (tp.seat_class is null or tp.seat_class = v_s.o_class)
     order by (tp.seat_class is not null) desc, tp.created_at desc
     limit 1;
    if not found then raise exception 'FARE_NOT_FOUND: no hay tarifa activa para el tramo y clase seleccionados'; end if;

    v_name := trim(coalesce(v_seat ->> 'passenger_name', ''));
    v_dni := regexp_replace(trim(coalesce(v_seat ->> 'passenger_dni', '')), '[^0-9]', '', 'g');
    if length(v_name) < 2 or length(v_name) > 150 or length(v_dni) < 6 then
      raise exception 'PASSENGER_INVALID: cargá nombre y apellido y DNI de cada pasajero';
    end if;
    v_qr := gen_random_uuid()::text;
    insert into public.sale_tickets (
      company_id, sale_id, trip_id, seat_label, layout_cell_id, from_stop_id, to_stop_id,
      passenger_name, passenger_dni, passenger_email, passenger_phone, price, qr_code, is_complimentary, status
    ) values (
      v_ctx.o_company, v_sale, p_trip, v_s.o_label, v_s.o_cell, v_s.o_from, v_s.o_to,
      v_name, v_dni, 'taquilla@pasajeros.ar', '0000000', v_price, v_qr, false, 'valid'
    ) returning id into v_id;
    v_total := v_total + v_price;
    v_tickets := v_tickets || jsonb_build_array(jsonb_build_object(
      'id', v_id, 'qr_code', v_qr, 'seat_label', v_s.o_label, 'price', v_price));
  end loop;

  update public.sales set total = v_total where id = v_sale;
  delete from public.seat_holds where trip_id = p_trip and (held_by = auth.uid() or expires_at <= clock_timestamp());
  return jsonb_build_object('sale_id', v_sale, 'tickets', v_tickets, 'total', v_total);
end $$;
revoke all on function public.taquilla_sell(uuid, public.payment_method, jsonb) from public, anon, authenticated;
grant execute on function public.taquilla_sell(uuid, public.payment_method, jsonb) to authenticated;

-- ---------------------------------------------------------------- ventanilla y web respetan las reservas de taquilla

alter function public.create_sale_with_tickets(uuid, public.payment_method, text, jsonb) rename to _create_sale_with_tickets_fares;
revoke all on function public._create_sale_with_tickets_fares(uuid, public.payment_method, text, jsonb) from public, anon, authenticated;
create function public.create_sale_with_tickets(
  p_trip uuid, p_payment_method public.payment_method, p_notes text, p_passengers jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_p jsonb;
  v_label text;
  v_from int;
  v_to int;
begin
  if jsonb_typeof(p_passengers) = 'array' then
    for v_p in select value from jsonb_array_elements(p_passengers)
    loop
      v_label := nullif(trim(coalesce(v_p ->> 'seat_label', '')), '');
      if v_label is null and nullif(v_p ->> 'layout_cell_id', '') is not null then
        select c.label into v_label from public.layout_cells c where c.id = (v_p ->> 'layout_cell_id')::uuid;
      end if;
      select position into v_from from public.route_stops where id = nullif(v_p ->> 'from_stop_id', '')::uuid;
      select position into v_to from public.route_stops where id = nullif(v_p ->> 'to_stop_id', '')::uuid;
      if v_label is not null and v_from is not null and v_to is not null and exists (
        select 1 from public._trip_seat_ranges(p_trip) r
         where r.kind = 'hold' and r.held_by is distinct from auth.uid()
           and r.seat_label = v_label and r.from_pos < v_to and r.to_pos > v_from
      ) then raise exception 'SEAT_TAKEN: el asiento está reservado por la taquilla unos minutos'; end if;
    end loop;
  end if;
  return public._create_sale_with_tickets_fares(p_trip, p_payment_method, p_notes, p_passengers);
end $$;
revoke all on function public.create_sale_with_tickets(uuid, public.payment_method, text, jsonb) from public, anon, authenticated;
grant execute on function public.create_sale_with_tickets(uuid, public.payment_method, text, jsonb) to authenticated;

alter function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, jsonb, text) rename to _begin_passenger_checkout_web;
revoke all on function public._begin_passenger_checkout_web(uuid, uuid, uuid, uuid, jsonb, text) from public, anon, authenticated;
create function public.begin_passenger_checkout(
  p_user uuid, p_trip uuid, p_from_stop uuid, p_to_stop uuid, p_tickets jsonb, p_phone text
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(p_tickets) = 'array' and exists (
    select 1
      from jsonb_array_elements(p_tickets) t(item)
      join public.layout_cells c on c.id::text = t.item ->> 'layout_cell_id'
      join public.route_stops fs on fs.id = p_from_stop
      join public.route_stops ts on ts.id = p_to_stop
      join public._trip_seat_ranges(p_trip) r on r.kind = 'hold' and r.seat_label = c.label
       and r.from_pos < ts.position and r.to_pos > fs.position
  ) then raise exception 'SEAT_TAKEN'; end if;
  return public._begin_passenger_checkout_web(p_user, p_trip, p_from_stop, p_to_stop, p_tickets, p_phone);
end $$;
revoke all on function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, jsonb, text) to service_role;

alter function public.public_trip_seats(uuid, uuid, uuid) rename to _public_trip_seats_web;
revoke all on function public._public_trip_seats_web(uuid, uuid, uuid) from public, anon, authenticated;
create function public.public_trip_seats(p_trip uuid, p_from_stop uuid, p_to_stop uuid)
returns table (
  cell_id uuid, floor int, row_idx int, col_idx int, seat_label text,
  seat_class text, available boolean, price numeric, cell_kind text
)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
  select s.cell_id, s.floor, s.row_idx, s.col_idx, s.seat_label, s.seat_class,
         s.available and not exists (
           select 1 from public._trip_seat_ranges(p_trip) r
             join public.route_stops fs on fs.id = p_from_stop
             join public.route_stops ts on ts.id = p_to_stop
            where r.kind = 'hold' and r.seat_label = s.seat_label
              and r.from_pos < ts.position and r.to_pos > fs.position),
         s.price, s.cell_kind
    from public._public_trip_seats_web(p_trip, p_from_stop, p_to_stop) s;
end $$;
revoke all on function public.public_trip_seats(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.public_trip_seats(uuid, uuid, uuid) to anon, authenticated;
