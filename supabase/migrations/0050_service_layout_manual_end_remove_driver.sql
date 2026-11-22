-- 0050: disposición de asientos por servicio, cierre manual de viajes y baja de conductores.
--  * services.layout_id: el servicio define la disposición de asientos (no depende de la unidad).
--    Los viajes nacen con esa disposición, se publican sin unidad ni conductor y al iniciar solo
--    sirve una unidad con la misma disposición. Los servicios sin disposición siguen igual que antes.
--  * admin_end_trip: el administrador finaliza a mano un viaje colgado (hora y motivo quedan registrados).
--  * remove_driver: baja de conductor (se borra si nunca tuvo actividad; si la tuvo se oculta y se conserva el historial).

alter table public.services add column if not exists layout_id uuid references public.seat_layouts (id);
alter table public.trips    add column if not exists ended_manually boolean not null default false;
alter table public.trips    add column if not exists end_reason text;
alter table public.profiles add column if not exists deleted_at timestamptz;

-- Última versión de la disposición del servicio (las versiones de un mismo grupo son "la misma disposición").
create or replace function public._service_layout(p_service uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select l2.id
    from public.services s
    join public.seat_layouts l1 on l1.id = s.layout_id
    join public.seat_layouts l2 on l2.group_id = l1.group_id
   where s.id = p_service
   order by l2.version desc
   limit 1;
$$;
revoke all on function public._service_layout(uuid) from public, anon;

create or replace function public._layout_group(p_layout uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select group_id from public.seat_layouts where id = p_layout;
$$;
revoke all on function public._layout_group(uuid) from public, anon;

-- guard_trip: igual que en 0013, más la disposición del servicio.
create or replace function public.guard_trip() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_vehicle   public.vehicles;
  v_driver    public.profiles;
  v_trip_rpc  boolean;
  v_svc_layout uuid;
begin
  v_trip_rpc := coalesce(current_setting('app.trip_rpc', true), '') = 'on';
  v_svc_layout := public._service_layout(new.service_id);

  -- el viaje nace con la disposición del servicio (si la tiene), sin necesidad de unidad
  if tg_op = 'INSERT' and new.layout_id is null and v_svc_layout is not null then
    new.layout_id := v_svc_layout;
  end if;

  if new.vehicle_id is not null and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id) then
    if tg_op = 'UPDATE' and old.status <> 'scheduled'
       and not (
         v_trip_rpc and new.status = 'in_progress'
         and (
           old.status = 'completed'
           or (old.status = 'in_progress' and new.driver_id is distinct from old.driver_id)
         )
       ) then
      raise exception 'TRIP_NOT_EDITABLE: el vehículo solo se cambia al relevar o retomar un viaje con el RPC autorizado';
    end if;
    select * into v_vehicle from public.vehicles where id = new.vehicle_id;
    if v_vehicle.company_id <> new.company_id then raise exception 'VEHICLE_OTHER_COMPANY'; end if;

    if v_svc_layout is null then
      new.layout_id := v_vehicle.layout_id;   -- servicio sin disposición: como antes
    else
      -- la disposición del viaje manda (el admin puede cambiarla viaje por viaje); si no tiene, la del servicio
      if new.layout_id is null then new.layout_id := v_svc_layout; end if;
      if v_vehicle.layout_id is null
         or public._layout_group(v_vehicle.layout_id) is distinct from public._layout_group(new.layout_id) then
        raise exception 'VEHICLE_LAYOUT_MISMATCH: la unidad no tiene la disposición de asientos de este servicio';
      end if;
    end if;
  end if;

  if new.driver_id is not null and (tg_op = 'INSERT' or new.driver_id is distinct from old.driver_id) then
    select * into v_driver from public.profiles where id = new.driver_id;
    if v_driver.company_id is distinct from new.company_id or v_driver.role <> 'driver' then
      raise exception 'DRIVER_INVALID: el conductor no pertenece a la empresa';
    end if;
  end if;

  if tg_op = 'UPDATE' and old.status in ('in_progress', 'completed')
     and new.driver_id is distinct from old.driver_id
     and not (v_trip_rpc and new.status = 'in_progress') then
    raise exception 'USE_RPC: el cambio de conductor requiere una transferencia autorizada';
  end if;

  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if not (
      (old.status = 'scheduled' and new.status in ('in_progress', 'cancelled'))
      or (old.status = 'in_progress' and new.status = 'completed')
      or (old.status = 'completed' and new.status = 'in_progress' and v_trip_rpc)
    ) then
      raise exception 'INVALID_TRANSITION: % -> %', old.status, new.status;
    end if;
    if new.status in ('in_progress', 'completed') and not v_trip_rpc then
      raise exception 'USE_RPC: el estado se cambia con start_service / end_trip';
    end if;
  end if;
  return new;
end $$;

-- Disposición del servicio (null la quita). Afecta a los viajes que se generen desde ahora.
create or replace function public.set_service_layout(p_service uuid, p_layout uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid := public.current_company_id();
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.services where id = p_service and company_id = v_company and deleted_at is null) then
    raise exception 'NOT_FOUND';
  end if;
  if p_layout is not null and not exists (select 1 from public.seat_layouts where id = p_layout and company_id = v_company) then
    raise exception 'LAYOUT_INVALID: la disposición no pertenece a la empresa';
  end if;
  update public.services set layout_id = p_layout where id = p_service;
end $$;
revoke all on function public.set_service_layout(uuid, uuid) from public, anon;
grant execute on function public.set_service_layout(uuid, uuid) to authenticated;

-- Cambia la disposición de un viaje programado (por ejemplo, sale una unidad distinta). Sin pasajes vendidos.
create or replace function public.admin_set_trip_layout(p_trip uuid, p_layout uuid) returns public.trips
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_trip    public.trips;
  v_vehicle public.vehicles;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  select * into v_trip from public.trips where id = p_trip and company_id = v_company for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'scheduled' then raise exception 'INVALID_STATE: solo se cambia en viajes programados'; end if;
  if not exists (select 1 from public.seat_layouts where id = p_layout and company_id = v_company) then
    raise exception 'LAYOUT_INVALID: la disposición no pertenece a la empresa';
  end if;
  if exists (select 1 from public.sale_tickets k where k.trip_id = p_trip) then
    raise exception 'TRIP_HAS_SALES: el viaje ya tiene pasajes; no se puede cambiar la disposición';
  end if;
  update public.trips set layout_id = p_layout where id = p_trip returning * into v_trip;
  -- la unidad asignada deja de servir si tiene otra disposición
  select * into v_vehicle from public.vehicles where id = v_trip.vehicle_id;
  if found and public._layout_group(v_vehicle.layout_id) is distinct from public._layout_group(p_layout) then
    update public.trips set vehicle_id = null where id = p_trip returning * into v_trip;
  end if;
  return v_trip;
end $$;
revoke all on function public.admin_set_trip_layout(uuid, uuid) from public, anon;
grant execute on function public.admin_set_trip_layout(uuid, uuid) to authenticated;

-- Para cada servicio con disposición: las unidades de la empresa que la tienen. {service_id: [vehicle_id, ...]}
-- Los servicios sin disposición no aparecen (aceptan cualquier unidad). Lo usan el panel y la app del conductor.
create or replace function public.service_layout_vehicles() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(s.id, coalesce((
           select jsonb_agg(v.id)
             from public.vehicles v
             join public.seat_layouts vl on vl.id = v.layout_id
            where v.company_id = s.company_id and vl.group_id = sl.group_id
         ), '[]'::jsonb)), '{}'::jsonb)
    from public.services s
    join public.seat_layouts sl on sl.id = s.layout_id
   where s.company_id = public.current_company_id() and s.deleted_at is null;
$$;
revoke all on function public.service_layout_vehicles() from public, anon;
grant execute on function public.service_layout_vehicles() to authenticated;

-- Llegada prevista de un viaje: salida + el último tiempo por parada del servicio.
create or replace function public.trip_expected_arrival(p_trip uuid) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare v_arrival timestamptz;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  select t.scheduled_departure + make_interval(mins => coalesce(max(ss.minutes_from_start), 0))
    into v_arrival
    from public.trips t
    join public.service_departures d on d.id = t.departure_id
    left join public.route_stops rs on rs.route_id = d.route_id
    left join public.service_stops ss on ss.route_stop_id = rs.id and ss.service_id = t.service_id
   where t.id = p_trip and t.company_id = public.current_company_id()
   group by t.scheduled_departure;
  return v_arrival;
end $$;
revoke all on function public.trip_expected_arrival(uuid) from public, anon;
grant execute on function public.trip_expected_arrival(uuid) to authenticated;

-- Finalización manual de un viaje en curso (colgado). Queda registrado quién, cuándo y por qué.
create or replace function public.admin_end_trip(p_trip uuid, p_ended_at timestamptz, p_reason text) returns public.trips
language plpgsql security definer set search_path = public as $$
declare
  v_trip public.trips;
  v_end  timestamptz;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'REASON_REQUIRED: escribí el motivo'; end if;
  select * into v_trip from public.trips
   where id = p_trip and company_id = public.current_company_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'in_progress' then raise exception 'INVALID_STATE: el viaje no está en curso'; end if;
  v_end := coalesce(p_ended_at, now());
  if v_end > now() + interval '1 minute' then raise exception 'END_IN_FUTURE: la hora de fin no puede ser futura'; end if;
  if v_end < v_trip.started_at then raise exception 'END_BEFORE_START: la hora de fin es anterior al inicio'; end if;

  perform set_config('app.trip_rpc', 'on', true);
  update public.trips
     set status = 'completed', ended_at = v_end, ended_manually = true, end_reason = trim(p_reason)
   where id = p_trip returning * into v_trip;
  return v_trip;
end $$;
revoke all on function public.admin_end_trip(uuid, timestamptz, text) from public, anon;
grant execute on function public.admin_end_trip(uuid, timestamptz, text) to authenticated;

-- Baja de conductor. Sin actividad: se borra del todo. Con actividad: se oculta, se bloquea el acceso y se
-- libera el correo; el historial (viajes, ventas, jornadas) se conserva.
create or replace function public.remove_driver(p_driver uuid) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_company uuid := public.current_company_id();
  v_driver  public.profiles;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  select * into v_driver from public.profiles
   where id = p_driver and company_id = v_company and role = 'driver' and deleted_at is null for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if exists (select 1 from public.trips where driver_id = p_driver and status = 'in_progress') then
    raise exception 'DRIVER_IN_PROGRESS: el conductor tiene un viaje en curso; finalizalo primero';
  end if;
  if exists (select 1 from public.shifts where driver_id = p_driver and ended_at is null) then
    raise exception 'DRIVER_SHIFT_OPEN: el conductor tiene una jornada abierta';
  end if;

  -- los viajes futuros quedan sin conductor asignado
  update public.trips set driver_id = null where driver_id = p_driver and status = 'scheduled';

  begin
    delete from public.profiles where id = p_driver;
    delete from auth.users where id = p_driver;
    return jsonb_build_object('deleted', true, 'kept_history', false);
  exception when foreign_key_violation then
    update public.profiles set active = false, deleted_at = now() where id = p_driver;
    update auth.users
       set email = 'eliminado-' || p_driver::text || '@eliminado.invalid',
           banned_until = 'infinity'
     where id = p_driver;
    return jsonb_build_object('deleted', true, 'kept_history', true);
  end;
end $$;
revoke all on function public.remove_driver(uuid) from public, anon;
grant execute on function public.remove_driver(uuid) to authenticated;

notify pgrst, 'reload schema';
