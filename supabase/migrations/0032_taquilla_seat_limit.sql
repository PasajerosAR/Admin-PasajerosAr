-- La taquilla aceptaba como máximo 10 asientos por vez ("SEAT_INVALID" sin explicación). Ahora hasta 60 (un micro grande completo)
-- y el mensaje dice qué pasó.

create or replace function public.taquilla_hold_seats(p_trip uuid, p_seats jsonb)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  v_ctx record;
  v_seat jsonb;
  v_s record;
  v_expires timestamptz := clock_timestamp() + make_interval(mins => public.taquilla_hold_minutes());
begin
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) > 60 then raise exception 'SEAT_INVALID: se pueden elegir hasta 60 asientos por vez'; end if;
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

create or replace function public.taquilla_sell(p_trip uuid, p_payment_method public.payment_method, p_seats jsonb)
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
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) < 1 or jsonb_array_length(p_seats) > 60 then
    raise exception 'SALE_INVALID: elegí entre 1 y 60 asientos';
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

