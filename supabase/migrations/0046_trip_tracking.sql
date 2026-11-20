-- Seguimiento de un viaje para la web: posicion, recorrido completo y hora estimada de llegada a cada parada.
-- Publico: mientras el viaje todavia se vende (hasta 5 minutos antes de la salida).
-- Pasajero con pasaje (sesion iniciada): desde que el viaje esta publicado hasta que se finaliza.
-- La hora estimada corrige el horario programado con el atraso o adelanto real de la unidad.
create or replace function public.trip_tracking(p_trip uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_trip public.trips;
  v_route uuid;
  v_public boolean;
  v_mine jsonb;
  v_pos record;
  v_has_pos boolean := false;
  v_k int;
  v_t double precision;
  v_dist double precision;
  v_ma int;
  v_mb int;
  v_first int;
  v_delay interval := interval '0';
  v_stops jsonb;
  v_head record;
begin
  select * into v_trip from public.trips
   where id = p_trip and status in ('scheduled', 'in_progress') and published_at is not null;
  if not found then return null; end if;
  if not exists (select 1 from public.companies where id = v_trip.company_id and active) then return null; end if;
  if not public.company_feature_enabled(v_trip.company_id, 'gps') then return null; end if;

  v_public := v_trip.scheduled_departure > now() + interval '5 minutes'
              and public.company_feature_enabled(v_trip.company_id, 'web');
  select coalesce(jsonb_agg(jsonb_build_object('from_stop_id', k.from_stop_id, 'to_stop_id', k.to_stop_id)), '[]'::jsonb)
    into v_mine
    from public.sale_tickets k
   where k.trip_id = p_trip and k.passenger_user_id = auth.uid() and k.status <> 'cancelled';
  if not (v_public or jsonb_array_length(v_mine) > 0) then return null; end if;

  select d.route_id into v_route from public.service_departures d where d.id = v_trip.departure_id;

  if v_trip.status = 'in_progress' then
    select l.latitude, l.longitude, l.accuracy_m, l.heading, l.recorded_at into v_pos
      from public.trip_live_positions l
     where l.trip_id = p_trip and l.recorded_at > now() - interval '90 seconds';
    v_has_pos := found;
  end if;

  select min(position) into v_first from public.route_stops where route_id = v_route;

  if v_has_pos then
    with s as (
      select rs.position, rs.lat::double precision as lat, rs.lng::double precision as lng, ss.minutes_from_start as m
        from public.route_stops rs
        left join public.service_stops ss on ss.service_id = v_trip.service_id and ss.route_stop_id = rs.id
       where rs.route_id = v_route
    )
    select best.k, best.t, best.dist, best.ma, best.mb into v_k, v_t, v_dist, v_ma, v_mb
      from (
        select a.position as k, a.m as ma, b.m as mb, tt.t,
               sqrt(power(q.px - tt.t * q.dx, 2) + power(q.py - tt.t * q.dy, 2)) as dist
          from s a
          join s b on b.position = (select min(x.position) from s x where x.position > a.position)
          cross join lateral (select cos(radians(a.lat)) * 111320 as kx) c
          cross join lateral (select (v_pos.longitude - a.lng) * c.kx as px, (v_pos.latitude - a.lat) * 110540 as py,
                                     (b.lng - a.lng) * c.kx as dx, (b.lat - a.lat) * 110540 as dy) q
          cross join lateral (select least(1, greatest(0, coalesce((q.px * q.dx + q.py * q.dy) / nullif(q.dx * q.dx + q.dy * q.dy, 0), 0))) as t) tt
         where a.lat is not null and a.lng is not null and b.lat is not null and b.lng is not null
           and a.m is not null and b.m is not null
         order by dist
         limit 1
      ) best;
    if v_k is not null and v_dist <= 2000 then
      v_delay := now() - (v_trip.scheduled_departure + (v_ma + v_t * (v_mb - v_ma)) * interval '1 minute');
      -- esperando en el origen: no se adelanta antes de la hora de salida
      if v_k = v_first and v_t < 0.05 then v_delay := greatest(v_delay, interval '0'); end if;
    else
      v_k := null;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'name', x.name, 'position', x.position, 'lat', x.lat, 'lng', x.lng,
           'scheduled_at', x.sched,
           'passed', x.passed,
           'eta_at', case when x.passed or x.sched is null then null else greatest(x.sched + v_delay, now()) end
         ) order by x.position), '[]'::jsonb)
    into v_stops
    from (
      select rs.id, rs.name, rs.position, rs.lat, rs.lng,
             v_trip.scheduled_departure + ss.minutes_from_start * interval '1 minute' as sched,
             (v_k is not null and (rs.position < v_k or (rs.position = v_k and v_t > 0.05))) as passed
        from public.route_stops rs
        left join public.service_stops ss on ss.service_id = v_trip.service_id and ss.route_stop_id = rs.id
       where rs.route_id = v_route
    ) x;

  select c.name as company_name, s.code as service_code, r.name as route_name, r.path as route_path
    into v_head
    from public.companies c, public.services s, public.routes r
   where c.id = v_trip.company_id and s.id = v_trip.service_id and r.id = v_route;

  return jsonb_build_object(
    'trip_id', p_trip,
    'company_name', v_head.company_name, 'service_code', v_head.service_code, 'route_name', v_head.route_name,
    'route_path', v_head.route_path,
    'status', v_trip.status,
    'scheduled_departure', v_trip.scheduled_departure,
    'origin_name', (select name from public.route_stops where route_id = v_route order by position limit 1),
    'destination_name', (select name from public.route_stops where route_id = v_route order by position desc limit 1),
    'signal', v_has_pos,
    'position', case when v_has_pos then jsonb_build_object('latitude', v_pos.latitude, 'longitude', v_pos.longitude,
      'accuracy_m', v_pos.accuracy_m, 'heading', v_pos.heading, 'recorded_at', v_pos.recorded_at) end,
    'delay_minutes', case when v_has_pos and v_k is not null then round(extract(epoch from v_delay) / 60)::int end,
    'stops', v_stops,
    'my_stops', v_mine,
    'server_time', now()
  );
end $$;
revoke all on function public.trip_tracking(uuid) from public;
grant execute on function public.trip_tracking(uuid) to anon, authenticated;
notify pgrst, 'reload schema';
