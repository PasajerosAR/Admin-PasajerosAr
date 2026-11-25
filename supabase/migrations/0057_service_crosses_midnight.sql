-- Servicios que pasan las 00:00: la salida puede ser del dia siguiente.
--  * service_departures.next_day marca las salidas de madrugada del servicio (ej.: sale 21:00 y vuelve 00:45).
--  * El viaje sigue perteneciendo al dia del servicio (service_date, tipo de dia, venta), pero su horario real
--    (scheduled_departure) cae en el dia calendario siguiente.
--  * generate_trips, start_service, advance_service_trip y save_service usan departure_ts(...).
alter table public.service_departures add column next_day boolean not null default false;

create function public.departure_ts(p_date date, p_time time, p_next_day boolean) returns timestamptz
language sql stable as $$
  select ((p_date + case when p_next_day then 1 else 0 end) + p_time) at time zone 'America/Argentina/Buenos_Aires'
$$;
grant execute on function public.departure_ts(date, time, boolean) to authenticated, service_role;

-- generar viajes
create or replace function public.generate_trips(p_date date, p_day_type text default null) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_type    text := coalesce(p_day_type, public.day_type_of(p_date));
  v_n int;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if v_type not in ('weekday','saturday','sunday','holiday') then raise exception 'DAY_TYPE_INVALID: tipo de dia invalido'; end if;
  -- los viajes generados quedan como borrador (published_at null) hasta que se usa publish_trips
  insert into public.trips (company_id, service_id, departure_id, service_date, scheduled_departure, day_type, published_at)
  select d.company_id, d.service_id, d.id, p_date, public.departure_ts(p_date, d.departure_time, d.next_day), v_type, null
  from public.service_departures d
  join public.services s on s.id = d.service_id
  where d.company_id = v_company and s.active and d.active and v_type = any (d.day_types)
  on conflict (departure_id, service_date) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- iniciar servicio (declarado por el conductor)
create or replace function public.start_service(
  p_service uuid, p_departure uuid, p_day_type text, p_vehicle uuid,
  p_reason text default null, p_service_date date default null
) returns public.trips
language plpgsql security definer set search_path = public as $$
declare
  v_company      uuid := public.current_company_id();
  v_dep          public.service_departures;
  v_veh          public.vehicles;
  v_trip         public.trips;
  v_exists       boolean := false;
  v_takeover     boolean := false;
  v_reopen       boolean := false;
  v_service_date date := coalesce(p_service_date, (now() at time zone 'America/Argentina/Buenos_Aires')::date);
  v_sched        timestamptz;
  v_forced       boolean;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_day_type is null or p_day_type not in ('weekday','saturday','sunday','holiday') then
    raise exception 'DAY_TYPE_INVALID: elija el tipo de dia';
  end if;
  if not exists (select 1 from public.shifts where driver_id = auth.uid() and ended_at is null) then
    raise exception 'NO_OPEN_SHIFT: inicie la jornada primero';
  end if;
  if exists (select 1 from public.trips where driver_id = auth.uid() and status = 'in_progress') then
    raise exception 'TRIP_IN_PROGRESS: ya tiene un viaje en curso';
  end if;

  select d.* into v_dep from public.service_departures d
    join public.services s on s.id = d.service_id
   where d.id = p_departure and d.service_id = p_service and d.company_id = v_company and d.active and s.active;
  if not found then raise exception 'NOT_FOUND: la salida no existe o esta pausada'; end if;
  if not (p_day_type = any (v_dep.day_types)) then
    raise exception 'DAY_TYPE_MISMATCH: esa salida no circula en ese tipo de dia';
  end if;

  select * into v_trip
    from public.trips
   where departure_id = p_departure and service_id = p_service
     and company_id = v_company and service_date = v_service_date
   for update;
  v_exists := found;

  if v_exists then
    if v_trip.status = 'scheduled' then
      if v_trip.driver_id is not null and v_trip.driver_id <> auth.uid() then
        raise exception 'TAKEN: esa salida esta asignada a otro conductor';
      end if;
    elsif v_trip.status = 'in_progress' then
      if v_trip.driver_id = auth.uid() then
        raise exception 'TRIP_IN_PROGRESS: ya tiene un viaje en curso';
      end if;
      if p_reason is null or length(trim(p_reason)) < 3 then
        raise exception 'TAKEOVER_REASON_REQUIRED: escribí el motivo para relevar al conductor actual';
      end if;
      v_takeover := true;
    elsif v_trip.status = 'completed' then
      if p_reason is null or length(trim(p_reason)) < 3 then
        raise exception 'REOPEN_REASON_REQUIRED: escribí el motivo para retomar el viaje finalizado';
      end if;
      v_reopen := true;
    else
      raise exception 'INVALID_STATE: el viaje cancelado no se puede retomar';
    end if;
  end if;

  select * into v_veh from public.vehicles where id = p_vehicle and company_id = v_company;
  if not found then raise exception 'NO_VEHICLE: elija la unidad'; end if;
  if v_veh.status in ('maintenance', 'out_of_service', 'retired') then
    raise exception 'VEHICLE_UNAVAILABLE: la unidad no esta disponible';
  end if;
  if exists (
    select 1 from public.trips t
     where t.vehicle_id = p_vehicle and t.status = 'in_progress'
       and (not v_exists or t.id <> v_trip.id)
  ) then
    raise exception 'VEHICLE_BUSY: la unidad ya tiene un viaje en curso';
  end if;

  v_sched := public.departure_ts(v_service_date, v_dep.departure_time, v_dep.next_day);
  v_forced := abs(extract(epoch from (now() - v_sched))) > 45 * 60;
  if v_forced and (p_reason is null or length(trim(p_reason)) < 3) then
    raise exception 'REASON_REQUIRED: la salida esta fuera de horario (mas de 45 minutos); indique el motivo';
  end if;

  perform set_config('app.trip_rpc', 'on', true);
  if v_exists then
    update public.trips
       set driver_id = auth.uid(),
           vehicle_id = p_vehicle,
           day_type = p_day_type,
           status = 'in_progress',
           started_at = now(),
           ended_at = null,
           started_manually = v_forced or v_takeover or v_reopen,
           start_reason = case when v_forced or v_takeover or v_reopen then trim(p_reason) end
     where id = v_trip.id
     returning * into v_trip;
  else
    insert into public.trips (
      company_id, service_id, departure_id, service_date, scheduled_departure,
      day_type, vehicle_id, driver_id
    )
    values (
      v_company, p_service, p_departure, v_service_date, v_sched,
      p_day_type, p_vehicle, auth.uid()
    )
    returning * into v_trip;

    update public.trips
       set status = 'in_progress',
           started_at = now(),
           started_manually = v_forced,
           start_reason = case when v_forced then trim(p_reason) end
     where id = v_trip.id
     returning * into v_trip;
  end if;
  return v_trip;
end $$;

-- cambio de sentido / proxima salida
create or replace function public.advance_service_trip(p_trip uuid, p_next_departure uuid, p_force boolean default false, p_arrived boolean default false) returns public.trips
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_trip public.trips;
  v_next public.trips;
  v_departure public.service_departures;
  v_vehicle public.vehicles;
  v_onboard int;
  v_scheduled timestamptz;
  v_next_exists boolean := false;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;

  select * into v_trip
    from public.trips
   where id = p_trip and driver_id = auth.uid() and company_id = v_company
   for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'in_progress' then raise exception 'INVALID_STATE: el viaje no esta en curso'; end if;
  if v_trip.vehicle_id is null then raise exception 'NO_VEHICLE: el viaje no tiene unidad asignada'; end if;
  if not exists (select 1 from public.shifts where driver_id = auth.uid() and ended_at is null) then
    raise exception 'NO_OPEN_SHIFT: inicie la jornada primero';
  end if;
  if exists (select 1 from public.trips where driver_id = auth.uid() and status = 'in_progress' and id <> p_trip) then
    raise exception 'TRIP_IN_PROGRESS: ya tiene otro viaje en curso';
  end if;
  if exists (select 1 from public.trips where vehicle_id = v_trip.vehicle_id and status = 'in_progress' and id <> p_trip) then
    raise exception 'VEHICLE_BUSY: la unidad ya tiene otro viaje en curso';
  end if;

  v_onboard := public.trip_onboard(p_trip);
  if v_onboard > 0 and not (p_force or p_arrived) then
    raise exception 'ONBOARD_REMAINING: quedan % pasajeros registrados a bordo', v_onboard;
  end if;

  select d.* into v_departure
    from public.service_departures d
    join public.services s on s.id = d.service_id
   where d.id = p_next_departure
     and d.service_id = v_trip.service_id
     and d.company_id = v_company
     and d.active and s.active
     and v_trip.day_type = any(d.day_types);
  if not found then raise exception 'NEXT_TRIP_INVALID: la proxima salida no pertenece al servicio o no circula hoy'; end if;
  if p_next_departure = v_trip.departure_id then
    raise exception 'NEXT_TRIP_INVALID: la proxima salida debe ser distinta al viaje actual';
  end if;

  v_scheduled := public.departure_ts(v_trip.service_date, v_departure.departure_time, v_departure.next_day);
  if v_scheduled <= v_trip.scheduled_departure then
    raise exception 'NEXT_TRIP_INVALID: el horario siguiente debe ser posterior al viaje actual';
  end if;

  select * into v_vehicle from public.vehicles
   where id = v_trip.vehicle_id and company_id = v_company;
  if not found then raise exception 'NO_VEHICLE: no se encontro la unidad del viaje'; end if;

  select * into v_next from public.trips
   where departure_id = p_next_departure and service_date = v_trip.service_date
   for update;
  v_next_exists := found;
  if v_next_exists then
    if v_next.status <> 'scheduled' then
      raise exception 'NEXT_TRIP_UNAVAILABLE: la proxima salida ya fue iniciada o finalizada';
    end if;
    if v_next.driver_id is not null and v_next.driver_id <> auth.uid() then
      raise exception 'NEXT_TRIP_TAKEN: la proxima salida esta asignada a otro conductor';
    end if;
  end if;

  perform set_config('app.trip_rpc', 'on', true);
  update public.trips set status = 'completed', ended_at = now()
   where id = p_trip;

  if v_next_exists then
    update public.trips
       set driver_id = auth.uid(),
           vehicle_id = v_trip.vehicle_id,
           layout_id = v_vehicle.layout_id,
           day_type = v_trip.day_type,
           status = 'in_progress',
           started_at = now(),
           ended_at = null,
           started_manually = p_force,
           start_reason = case when p_force then 'Cambio de sentido forzado durante el viaje' end
     where id = v_next.id
     returning * into v_next;
  else
    insert into public.trips (
      company_id, service_id, departure_id, service_date, scheduled_departure,
      day_type, vehicle_id, layout_id, driver_id, status, started_at, started_manually, start_reason
    )
    values (
      v_company, v_trip.service_id, p_next_departure, v_trip.service_date, v_scheduled,
      v_trip.day_type, v_trip.vehicle_id, v_vehicle.layout_id, auth.uid(), 'in_progress', now(),
      p_force, case when p_force then 'Cambio de sentido forzado durante el viaje' end
    )
    returning * into v_next;
  end if;

  return v_next;
end $$;

-- guardar servicio (recibe next_day por salida)
create or replace function public.save_service(
  p_service uuid, p_code text, p_active boolean, p_departures jsonb, p_stops jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := public.current_company_id();
  v_id       uuid;
  v_routes   uuid[];
  v_expected int;
  v_prev     int;
  v_keep     uuid[];
  v_dep      jsonb;
  v_dep_id   uuid;
  v_old      public.service_departures;
  v_days     text[];
  r          record;
  rt         uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_code is null or length(trim(p_code)) = 0 then raise exception 'CODE_REQUIRED: falta el codigo del servicio'; end if;
  if p_departures is null or jsonb_typeof(p_departures) <> 'array' or jsonb_array_length(p_departures) = 0 then
    raise exception 'DEPARTURES_REQUIRED: agregue al menos una salida';
  end if;
  if p_stops is null or jsonb_typeof(p_stops) <> 'array' then raise exception 'STOPS_MISMATCH: faltan los tiempos de las paradas'; end if;

  -- validar cada salida
  for v_dep in select * from jsonb_array_elements(p_departures) loop
    if coalesce(v_dep ->> 'time', '') = '' then raise exception 'TIME_REQUIRED: falta la hora de una salida'; end if;
    select coalesce(array_agg(x), '{}') into v_days from jsonb_array_elements_text(coalesce(v_dep -> 'day_types', '[]'::jsonb)) x;
    if cardinality(v_days) = 0 or not (v_days <@ array['weekday','saturday','sunday','holiday']) then
      raise exception 'DAYS_INVALID: elija al menos un tipo de dia en cada salida';
    end if;
    if not exists (select 1 from public.routes where id = (v_dep ->> 'route_id')::uuid and active and company_id = v_company) then
      raise exception 'ROUTE_INVALID: el recorrido no existe, no esta activo o no es de su empresa';
    end if;
  end loop;
  if (select count(*) from jsonb_array_elements(p_departures) e)
     <> (select count(distinct (e ->> 'route_id') || '|' || (e ->> 'time')) from jsonb_array_elements(p_departures) e) then
    raise exception 'DEPARTURE_DUPLICATED: hay dos salidas iguales (mismo sentido y hora)';
  end if;

  select array_agg(distinct (e ->> 'route_id')::uuid) into v_routes from jsonb_array_elements(p_departures) e;

  -- tiempos: exactamente las paradas de los recorridos usados, sin repetir
  select count(*) into v_expected from public.route_stops where route_id = any (v_routes);
  if jsonb_array_length(p_stops) <> v_expected
     or (select count(distinct e ->> 'route_stop_id') from jsonb_array_elements(p_stops) e) <> v_expected
     or exists (select 1 from jsonb_array_elements(p_stops) e
                 where not exists (select 1 from public.route_stops rs
                                    where rs.route_id = any (v_routes) and rs.id::text = e ->> 'route_stop_id')) then
    raise exception 'STOPS_MISMATCH: los tiempos deben cubrir todas las paradas de los recorridos del servicio';
  end if;
  foreach rt in array v_routes loop
    v_prev := 0;
    for r in
      select rs.position, coalesce((e ->> 'minutes_from_start')::int, -1) as m
        from public.route_stops rs
        join jsonb_array_elements(p_stops) e on e ->> 'route_stop_id' = rs.id::text
       where rs.route_id = rt order by rs.position
    loop
      if r.m < 0 then raise exception 'TIMES_INVALID: falta el minuto de la parada %', r.position; end if;
      if r.position = 1 and r.m <> 0 then raise exception 'TIMES_INVALID: la primera parada sale en el minuto 0'; end if;
      if r.m < v_prev then raise exception 'TIMES_INVALID: los minutos no pueden disminuir entre paradas'; end if;
      v_prev := r.m;
    end loop;
  end loop;

  -- servicio
  if p_service is null then
    insert into public.services (company_id, code, active) values (v_company, trim(p_code), coalesce(p_active, true))
    returning id into v_id;
  else
    perform 1 from public.services where id = p_service and company_id = v_company for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    update public.services set code = trim(p_code), active = coalesce(p_active, active) where id = p_service;
    v_id := p_service;
  end if;
  perform set_config('app.service_rpc', 'on', true);

  -- salidas: actualizar las que vienen con id, crear las nuevas, quitar las que no vienen
  v_keep := '{}';
  for v_dep in select * from jsonb_array_elements(p_departures) loop
    select coalesce(array_agg(x), '{}') into v_days from jsonb_array_elements_text(v_dep -> 'day_types') x;
    v_dep_id := nullif(v_dep ->> 'id', '')::uuid;
    if v_dep_id is null then
      insert into public.service_departures (service_id, company_id, route_id, departure_time, next_day, day_types, active)
      values (v_id, v_company, (v_dep ->> 'route_id')::uuid, (v_dep ->> 'time')::time, coalesce((v_dep ->> 'next_day')::boolean, false), v_days, coalesce((v_dep ->> 'active')::boolean, true))
      returning id into v_dep_id;
    else
      select * into v_old from public.service_departures where id = v_dep_id and service_id = v_id and company_id = v_company for update;
      if not found then raise exception 'NOT_FOUND'; end if;
      if v_old.route_id <> (v_dep ->> 'route_id')::uuid and exists (select 1 from public.trips where departure_id = v_dep_id) then
        raise exception 'ROUTE_LOCKED: la salida ya tiene viajes; cree una nueva para cambiar de sentido';
      end if;
      update public.service_departures
         set route_id = (v_dep ->> 'route_id')::uuid, departure_time = (v_dep ->> 'time')::time,
             next_day = coalesce((v_dep ->> 'next_day')::boolean, false),
             day_types = v_days, active = coalesce((v_dep ->> 'active')::boolean, true)
       where id = v_dep_id;
      -- los viajes todavia sin iniciar acompañan el cambio de horario o de dia
      update public.trips t
         set scheduled_departure = public.departure_ts(t.service_date, (v_dep ->> 'time')::time, coalesce((v_dep ->> 'next_day')::boolean, false))
       where t.departure_id = v_dep_id and t.status = 'scheduled'
         and (v_old.departure_time <> (v_dep ->> 'time')::time or v_old.next_day <> coalesce((v_dep ->> 'next_day')::boolean, false));
    end if;
    v_keep := v_keep || v_dep_id;
  end loop;
  if exists (select 1 from public.service_departures d
              where d.service_id = v_id and d.id <> all (v_keep)
                and exists (select 1 from public.trips t where t.departure_id = d.id)) then
    raise exception 'DEPARTURE_HAS_TRIPS: una salida con viajes no se puede quitar; pausela';
  end if;
  delete from public.service_departures where service_id = v_id and id <> all (v_keep);

  delete from public.service_stops where service_id = v_id;
  insert into public.service_stops (service_id, route_stop_id, company_id, minutes_from_start, dwell_minutes)
  select v_id, (e ->> 'route_stop_id')::uuid, v_company,
         (e ->> 'minutes_from_start')::int, coalesce((e ->> 'dwell_minutes')::int, 0)
  from jsonb_array_elements(p_stops) e;
  return v_id;
end $$;
notify pgrst, 'reload schema';
