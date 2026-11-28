-- 0071: más bloqueos que el administrador general puede aplicar a la app del conductor:
--   pay_cash / pay_transfer   la taquilla no cobra en efectivo / por transferencia
--   pay_qr                    la taquilla no cobra por QR (hoy es una vista previa, se bloquea solo en la app)
--   clock                     sin marcaje de entrada y salida (foto y GPS): el conductor inicia y cierra la jornada tocando el botón
create or replace function public.known_company_features() returns text[]
language sql immutable as $$
  select array['web', 'gps', 'scanner', 'fares', 'incidents', 'counter', 'pay_cash', 'pay_transfer', 'pay_qr', 'clock'];
$$;

create or replace function public._clock_required(p_company uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.company_feature_enabled(p_company, 'clock')
     and exists (select 1 from public.clock_zones where company_id = p_company and active);
$$;

-- el marcaje se envuelve: la función original pasa a _punch_shift_impl y la nueva comprueba el bloqueo
alter function public.punch_shift(text, uuid, double precision, double precision, double precision, timestamptz) rename to _punch_shift_impl;
revoke all on function public._punch_shift_impl(text, uuid, double precision, double precision, double precision, timestamptz) from public, anon, authenticated;
create function public.punch_shift(p_kind text, p_client_key uuid, p_lat double precision, p_lng double precision, p_accuracy double precision, p_captured_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.company_feature_enabled(public.current_company_id(), 'clock') then
    raise exception 'FEATURE_BLOCKED: el marcaje no está habilitado para esta empresa';
  end if;
  return public._punch_shift_impl(p_kind, p_client_key, p_lat, p_lng, p_accuracy, p_captured_at);
end $$;
revoke all on function public.punch_shift(text, uuid, double precision, double precision, double precision, timestamptz) from public, anon;
grant execute on function public.punch_shift(text, uuid, double precision, double precision, double precision, timestamptz) to authenticated;

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
  v_board boolean;
  v_event uuid;
begin
  if p_payment_method not in ('cash', 'transfer', 'debit', 'credit')
     or (v_role = 'driver' and p_payment_method in ('debit', 'credit')) then
    raise exception 'PAYMENT_INVALID: forma de pago no habilitada';
  end if;
  -- formas de pago que el administrador general puede bloquear para la taquilla del conductor
  if v_role = 'driver' and (
       (p_payment_method = 'cash' and not public.company_feature_enabled(public.current_company_id(), 'pay_cash'))
    or (p_payment_method = 'transfer' and not public.company_feature_enabled(public.current_company_id(), 'pay_transfer'))) then
    raise exception 'FEATURE_BLOCKED: esa forma de cobro no está habilitada para esta empresa';
  end if;
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) < 1 or jsonb_array_length(p_seats) > 20 then
    raise exception 'SALE_INVALID: elegí al menos un asiento';
  end if;
  select * into v_ctx from public._taquilla_ctx(p_trip, true);
  -- venta del chofer en un viaje en curso: el pasajero sube ahora, así que se cuenta a bordo (como una lectura de QR)
  v_board := v_role = 'driver'
    and exists (select 1 from public.trips where id = p_trip and status = 'in_progress')
    and public.company_feature_enabled(v_ctx.o_company, 'counter');

  insert into public.sales (company_id, seller_id, trip_id, payment_method, total, notes)
  values (v_ctx.o_company, auth.uid(), p_trip, p_payment_method, 0, case when v_role = 'driver' then 'Venta en taquilla' else 'Venta en ventanilla' end)
  returning id into v_sale;

  for v_seat in select value from jsonb_array_elements(p_seats)
  loop
    select * into v_s from public._taquilla_seat(p_trip, v_ctx.o_route, v_ctx.o_layout, v_seat);
    select tp.price into v_fare from public.ticket_prices tp
     where tp.company_id = v_ctx.o_company and tp.route_id = v_ctx.o_route
       and tp.from_pos = v_s.o_from_pos and tp.to_pos = v_s.o_to_pos and tp.active
       and tp.day_type = (select tr.fare_band from public.trips tr where tr.id = p_trip)
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
    if v_board then
      v_event := gen_random_uuid();
      perform public.register_count(p_trip, 'board', 1, v_s.o_from, v_event);
      update public.sale_tickets
         set status = 'boarded', boarded_at = clock_timestamp(), boarded_by = auth.uid(),
             actual_boarding_stop_id = v_s.o_from, boarding_event_id = v_event
       where id = v_id;
    end if;
    v_total := v_total + v_price;
    v_tickets := v_tickets || jsonb_build_array(jsonb_build_object(
      'id', v_id, 'qr_code', v_qr, 'seat_label', v_s.o_label, 'price', v_price,
      'passenger_name', v_name, 'passenger_dni', v_dni, 'email', case when v_email = 'taquilla@pasajeros.ar' then null else v_email end,
      'from_stop_id', v_s.o_from, 'to_stop_id', v_s.o_to, 'ticket_type', v_ticket_type, 'boarded', v_board));
  end loop;

  update public.sales
     set total = v_total,
         payment_method = case when v_total = 0 then 'complimentary'::public.payment_method else p_payment_method end
   where id = v_sale;
  delete from public.seat_holds where trip_id = p_trip and (held_by = auth.uid() or expires_at <= clock_timestamp());
  return jsonb_build_object('sale_id', v_sale, 'tickets', v_tickets, 'total', v_total);
end $function$;
