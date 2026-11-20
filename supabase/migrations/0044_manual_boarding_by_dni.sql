-- Ascenso manual de pasajes vendidos (sin GPS confiable o buscando por DNI).
-- Queda registrado como autorizado por el conductor (boarding_override), igual que "Permitir ascenso aquí".

create or replace function public._board_sale_ticket_manual(p_trip uuid, p_ticket uuid, p_stop uuid, p_event uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_trip public.trips;
  v_ticket public.sale_tickets;
  v_route uuid;
  v_stop uuid;
  v_stop_name text;
  v_actual_pos int;
  v_board_pos int;
  v_alight_pos int;
  v_counts jsonb;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_event is null then raise exception 'EVENT_REQUIRED'; end if;
  select * into v_trip from public.trips
   where id = p_trip and company_id = public.current_company_id() and driver_id = auth.uid() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'in_progress' then raise exception 'INVALID_STATE: el viaje no está en curso'; end if;
  select d.route_id into v_route from public.service_departures d where d.id = v_trip.departure_id;

  select * into v_ticket from public.sale_tickets where id = p_ticket and trip_id = p_trip for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'INVALID_TICKET', 'title', 'Pasaje no encontrado', 'detail', 'No se encontró el pasaje en este viaje.');
  end if;
  if v_ticket.status = 'cancelled' then
    return jsonb_build_object('ok', false, 'code', 'CANCELLED', 'title', 'Pasaje anulado', 'detail', 'El pasaje fue anulado y no puede abordar.');
  end if;
  if v_ticket.status = 'boarded' then
    if v_ticket.boarding_event_id = p_event then
      return jsonb_build_object('ok', true, 'code', v_ticket.qr_code, 'title', 'Ascenso ya registrado', 'detail', 'Esta lectura ya había sido procesada.');
    end if;
    return jsonb_build_object('ok', false, 'code', 'ALREADY_BOARDED', 'title', 'Pasaje ya utilizado', 'detail', 'Este pasaje ya fue validado.');
  end if;

  v_stop := coalesce(p_stop, v_ticket.from_stop_id);
  select name, position into v_stop_name, v_actual_pos from public.route_stops where id = v_stop and route_id = v_route;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'STOP_INVALID', 'title', 'Parada inválida', 'detail', 'La parada no pertenece al recorrido.');
  end if;
  select position into v_board_pos from public.route_stops where id = v_ticket.from_stop_id and route_id = v_route;
  select position into v_alight_pos from public.route_stops where id = v_ticket.to_stop_id and route_id = v_route;
  if v_board_pos is null or v_alight_pos is null or v_board_pos >= v_alight_pos then
    return jsonb_build_object('ok', false, 'code', 'TICKET_ROUTE_INVALID', 'title', 'Pasaje inválido', 'detail', 'El tramo del pasaje no corresponde al recorrido.');
  end if;
  if v_actual_pos >= v_alight_pos then
    return jsonb_build_object('ok', false, 'code', 'PAST_ALIGHTING_STOP', 'title', 'Ascenso no permitido', 'detail', 'La unidad ya pasó la parada de descenso.');
  end if;
  if v_actual_pos < v_board_pos then
    return jsonb_build_object('ok', false, 'code', 'BOARDING_STOP_MISMATCH', 'title', 'Ascenso no permitido', 'detail', 'El pasaje corresponde a una parada posterior.');
  end if;

  v_counts := public.register_count(v_trip.id, 'board', 1, v_stop, p_event);
  update public.sale_tickets set status = 'boarded', boarded_at = clock_timestamp(), boarded_by = auth.uid(),
    actual_boarding_stop_id = v_stop, boarding_event_id = p_event,
    boarding_override = true, boarding_override_at = clock_timestamp(), boarding_override_by = auth.uid()
   where id = v_ticket.id;
  return v_counts || jsonb_build_object('ok', true, 'code', v_ticket.qr_code, 'title', 'Ascenso confirmado manualmente',
    'detail', format('Registrado en %s por el conductor.', v_stop_name), 'actual_stop', v_stop_name, 'boarding_override', true);
end $$;
revoke all on function public._board_sale_ticket_manual(uuid, uuid, uuid, uuid) from public, anon, authenticated;

-- QR leído sin GPS confiable: el conductor confirma a mano
create or replace function public.confirm_ticket_boarding(p_trip uuid, p_code text, p_stop uuid, p_event uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  select id into v_id from public.sale_tickets
   where qr_code = trim(coalesce(p_code, '')) and company_id = public.current_company_id();
  if v_id is null then
    return jsonb_build_object('ok', false, 'code', 'INVALID_TICKET', 'title', 'QR inválido', 'detail', 'No se encontró el pasaje.');
  end if;
  if not exists (select 1 from public.sale_tickets where id = v_id and trip_id = p_trip) then
    return jsonb_build_object('ok', false, 'code', 'OTHER_TRIP', 'title', 'Pasaje de otro viaje', 'detail', 'Este QR no pertenece al viaje actual.');
  end if;
  return public._board_sale_ticket_manual(p_trip, v_id, p_stop, p_event);
end $$;
revoke all on function public.confirm_ticket_boarding(uuid, text, uuid, uuid) from public, anon;
grant execute on function public.confirm_ticket_boarding(uuid, text, uuid, uuid) to authenticated;

-- Búsqueda por DNI dentro del viaje en curso del conductor
create or replace function public.lookup_ticket_by_dni(p_trip uuid, p_dni text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_dni text := regexp_replace(coalesce(p_dni, ''), '\D', '', 'g');
  v_pending int;
  v_k record;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.trips where id = p_trip and company_id = public.current_company_id() and driver_id = auth.uid()) then
    raise exception 'NOT_FOUND';
  end if;
  if v_dni !~ '^\d{7,8}$' then
    return jsonb_build_object('ok', false, 'can_board', false, 'title', 'DNI inválido', 'detail', 'Ingresá 7 u 8 números.');
  end if;
  select count(*) into v_pending from public.sale_tickets
   where trip_id = p_trip and regexp_replace(passenger_dni, '\D', '', 'g') = v_dni and status = 'valid';
  select k.passenger_name, k.seat_label, k.status, fs.name as from_name, ts.name as to_name into v_k
    from public.sale_tickets k
    join public.route_stops fs on fs.id = k.from_stop_id
    join public.route_stops ts on ts.id = k.to_stop_id
   where k.trip_id = p_trip and regexp_replace(k.passenger_dni, '\D', '', 'g') = v_dni and k.status <> 'cancelled'
   order by (k.status = 'valid') desc, fs.position, k.seat_label limit 1;
  if v_k.passenger_name is null then
    return jsonb_build_object('ok', false, 'can_board', false, 'title', 'Sin pasaje', 'detail', 'No hay un pasaje con ese DNI en este viaje.');
  end if;
  if v_pending = 0 then
    return jsonb_build_object('ok', true, 'can_board', false, 'title', 'Pasaje ya utilizado', 'detail', 'El pasaje de este DNI ya fue validado.',
      'passenger_name', v_k.passenger_name, 'boarding_stop', v_k.from_name, 'alighting_stop', v_k.to_name, 'seat', v_k.seat_label, 'pending', 0);
  end if;
  return jsonb_build_object('ok', true, 'can_board', true, 'title', 'Pasaje encontrado',
    'detail', case when v_pending > 1 then format('Hay %s pasajes pendientes con este DNI; se valida uno por vez.', v_pending) else 'Verificá los datos del pasajero antes de confirmar.' end,
    'passenger_name', v_k.passenger_name, 'boarding_stop', v_k.from_name, 'alighting_stop', v_k.to_name, 'seat', v_k.seat_label, 'pending', v_pending);
end $$;
revoke all on function public.lookup_ticket_by_dni(uuid, text) from public, anon;
grant execute on function public.lookup_ticket_by_dni(uuid, text) to authenticated;

create or replace function public.board_ticket_by_dni(p_trip uuid, p_dni text, p_stop uuid, p_event uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_dni text := regexp_replace(coalesce(p_dni, ''), '\D', '', 'g');
  v_id uuid;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  select k.id into v_id from public.sale_tickets k
    join public.route_stops fs on fs.id = k.from_stop_id
   where k.trip_id = p_trip and k.company_id = public.current_company_id()
     and regexp_replace(k.passenger_dni, '\D', '', 'g') = v_dni and k.status = 'valid'
   order by fs.position, k.seat_label limit 1;
  if v_id is null then
    return jsonb_build_object('ok', false, 'code', 'INVALID_TICKET', 'title', 'Sin pasaje pendiente', 'detail', 'No hay un pasaje pendiente con ese DNI en este viaje.');
  end if;
  return public._board_sale_ticket_manual(p_trip, v_id, p_stop, p_event);
end $$;
revoke all on function public.board_ticket_by_dni(uuid, text, uuid, uuid) from public, anon;
grant execute on function public.board_ticket_by_dni(uuid, text, uuid, uuid) to authenticated;
notify pgrst, 'reload schema';
