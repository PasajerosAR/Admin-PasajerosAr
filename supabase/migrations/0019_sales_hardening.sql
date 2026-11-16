-- Refuerza el modulo comercial y habilita permisos propios de plataforma.

alter table public.profiles drop constraint if exists profile_company_required;
alter table public.profiles add constraint profile_company_required
  check (role in ('platform_admin', 'platform_staff') or company_id is not null);

create or replace function public.has_platform_permission(p_section text, p_edit boolean default false)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    public.is_platform_admin()
    or (
      public.current_user_role() = 'platform_staff'
      and exists (
        select 1 from public.platform_permissions pp
         where pp.profile_id = auth.uid()
           and pp.section in (p_section, 'all')
           and (not p_edit or pp.can_edit)
      )
    ),
    false
  )
$$;
revoke all on function public.has_platform_permission(text, boolean) from public, anon;
grant execute on function public.has_platform_permission(text, boolean) to authenticated;

drop policy pp_select on public.platform_permissions;
create policy pp_select on public.platform_permissions for select to authenticated
  using (public.is_platform_admin() or profile_id = auth.uid());

drop policy profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (
    id = auth.uid()
    or public.is_platform_admin()
    or (company_id = public.current_company_id() and public.current_user_role() in ('company_admin', 'support'))
  );
create policy profiles_platform_staff_update on public.profiles for update to authenticated
  using (public.is_platform_admin() and role = 'platform_staff')
  with check (public.is_platform_admin() and role = 'platform_staff' and company_id is null);

create policy companies_staff_select on public.companies for select to authenticated
  using (public.has_platform_permission('companies')
      or public.has_platform_permission('routes')
      or public.has_platform_permission('gps'));
create policy companies_staff_update on public.companies for update to authenticated
  using (public.has_platform_permission('companies', true))
  with check (public.has_platform_permission('companies', true));

create policy routes_staff_select on public.routes for select to authenticated
  using (public.has_platform_permission('routes'));
create policy routes_staff_update on public.routes for update to authenticated
  using (public.has_platform_permission('routes', true))
  with check (public.has_platform_permission('routes', true));
create policy route_stops_staff_select on public.route_stops for select to authenticated
  using (public.has_platform_permission('routes') or public.has_platform_permission('places'));
create policy route_stops_staff_update on public.route_stops for update to authenticated
  using (public.has_platform_permission('routes', true))
  with check (public.has_platform_permission('routes', true));

create policy places_staff_update on public.places for update to authenticated
  using (public.has_platform_permission('places', true))
  with check (public.has_platform_permission('places', true));
create policy places_staff_insert on public.places for insert to authenticated
  with check (public.has_platform_permission('places', true));
create policy places_staff_delete on public.places for delete to authenticated
  using (public.has_platform_permission('places', true));

create policy ticket_prices_delete on public.ticket_prices for delete to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin());

create or replace function public.save_route(
  p_route uuid, p_name text, p_active boolean, p_stops jsonb, p_company uuid,
  p_path jsonb default null, p_via jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_n int;
  v_prev_company uuid;
  v_first uuid;
  v_last uuid;
begin
  if not public.has_platform_permission('routes', true) then raise exception 'FORBIDDEN'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'NAME_REQUIRED: falta el nombre del recorrido'; end if;
  if p_company is null or not exists (select 1 from public.companies where id = p_company) then
    raise exception 'COMPANY_REQUIRED: elija la empresa dueña del recorrido';
  end if;
  if p_stops is null or jsonb_typeof(p_stops) <> 'array' or jsonb_array_length(p_stops) < 2 then
    raise exception 'STOPS_REQUIRED: el recorrido necesita al menos origen y destino';
  end if;
  if exists (select 1 from jsonb_array_elements(p_stops) e where coalesce(e ->> 'place_id', '') = '') then
    raise exception 'PLACE_REQUIRED: cada parada necesita su localidad';
  end if;
  if exists (select 1 from jsonb_array_elements(p_stops) e
              where not exists (select 1 from public.places pl where pl.id::text = e ->> 'place_id')) then
    raise exception 'PLACE_INVALID: una de las localidades no existe';
  end if;
  if p_path is not null and (jsonb_typeof(p_path) <> 'array' or jsonb_array_length(p_path) > 20000
      or exists (select 1 from jsonb_array_elements(p_path) e
                  where jsonb_typeof(e) <> 'array' or jsonb_array_length(e) <> 2)) then
    raise exception 'PATH_INVALID: el trazado no es válido';
  end if;
  if p_via is not null and (jsonb_typeof(p_via) <> 'array' or jsonb_array_length(p_via) > 200) then
    raise exception 'PATH_INVALID: los puntos de paso no son válidos';
  end if;

  v_first := (p_stops -> 0 ->> 'place_id')::uuid;
  v_last := (p_stops -> (jsonb_array_length(p_stops) - 1) ->> 'place_id')::uuid;

  if p_route is null then
    insert into public.routes (name, active, company_id, origin_place_id, destination_place_id, path, via)
    values (trim(p_name), coalesce(p_active, true), p_company, v_first, v_last, p_path, p_via)
    returning id into v_id;
  else
    select company_id into v_prev_company from public.routes where id = p_route for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if v_prev_company is distinct from p_company
       and exists (select 1 from public.service_departures where route_id = p_route) then
      raise exception 'COMPANY_LOCKED: hay servicios con este recorrido; no se puede cambiar de empresa';
    end if;
    update public.routes
       set name = trim(p_name), active = coalesce(p_active, active), company_id = p_company,
           origin_place_id = v_first, destination_place_id = v_last, path = p_path, via = p_via
     where id = p_route returning id into v_id;

    if exists (select 1 from public.service_departures where route_id = v_id) then
      select count(*) into v_n from public.route_stops where route_id = v_id;
      if jsonb_array_length(p_stops) <> v_n then
        raise exception 'ROUTE_IN_USE: hay servicios con este recorrido; solo se pueden corregir nombres, localidades y coordenadas';
      end if;
      update public.route_stops rs
         set name = trim(s.e ->> 'name'),
             lat = nullif(s.e ->> 'lat', '')::numeric,
             lng = nullif(s.e ->> 'lng', '')::numeric,
             place_id = (s.e ->> 'place_id')::uuid
        from jsonb_array_elements(p_stops) with ordinality as s(e, ord)
       where rs.route_id = v_id and rs.position = s.ord::int;
      return v_id;
    end if;
    delete from public.route_stops where route_id = v_id;
  end if;

  insert into public.route_stops (route_id, position, name, lat, lng, place_id)
  select v_id, s.ord::int, trim(s.e ->> 'name'), nullif(s.e ->> 'lat', '')::numeric,
         nullif(s.e ->> 'lng', '')::numeric, (s.e ->> 'place_id')::uuid
    from jsonb_array_elements(p_stops) with ordinality as s(e, ord);
  return v_id;
end
$$;
revoke all on function public.save_route(uuid, text, boolean, jsonb, uuid, jsonb, jsonb) from public, anon;
grant execute on function public.save_route(uuid, text, boolean, jsonb, uuid, jsonb, jsonb) to authenticated;

create or replace function public.save_route_maneuvers(p_route uuid, p_maneuvers jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_platform_permission('routes', true) then raise exception 'FORBIDDEN'; end if;
  if p_maneuvers is not null and (
    jsonb_typeof(p_maneuvers) <> 'array' or jsonb_array_length(p_maneuvers) > 2000
    or exists (
      select 1 from jsonb_array_elements(p_maneuvers) as item(m)
       where jsonb_typeof(m) <> 'object'
          or coalesce(jsonb_typeof(m -> 'lat'), 'null') <> 'number'
          or coalesce(jsonb_typeof(m -> 'lng'), 'null') <> 'number'
          or coalesce(jsonb_typeof(m -> 'type'), 'null') <> 'string'
          or length(trim(coalesce(m ->> 'type', ''))) = 0
          or length(m ->> 'type') > 40
          or coalesce(jsonb_typeof(m -> 'name'), 'null') <> 'string'
          or coalesce(jsonb_typeof(m -> 'modifier'), 'null') not in ('string', 'null')
          or coalesce(jsonb_typeof(m -> 'exit'), 'null') not in ('number', 'null')
          or case when jsonb_typeof(m -> 'lat') = 'number'
               then (m ->> 'lat')::numeric not between -90 and 90 else true end
          or case when jsonb_typeof(m -> 'lng') = 'number'
               then (m ->> 'lng')::numeric not between -180 and 180 else true end
          or case when jsonb_typeof(m -> 'exit') = 'number'
               then (m ->> 'exit')::numeric not between 1 and 100
                    or (m ->> 'exit')::numeric <> trunc((m ->> 'exit')::numeric)
               else false end
    )
  ) then raise exception 'PATH_INVALID: las indicaciones de giro no son válidas'; end if;

  update public.routes set maneuvers = p_maneuvers where id = p_route;
  if not found then raise exception 'NOT_FOUND'; end if;
end
$$;
revoke all on function public.save_route_maneuvers(uuid, jsonb) from public, anon;
grant execute on function public.save_route_maneuvers(uuid, jsonb) to authenticated;

create or replace function public.admin_live_trip_schedule(p_company_id uuid default null)
returns table (trip_id uuid, route_stops jsonb)
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  v_company uuid := public.current_company_id();
begin
  if v_role = 'company_admin' then
    if p_company_id is not null and p_company_id is distinct from v_company then raise exception 'FORBIDDEN'; end if;
  elsif not public.has_platform_permission('gps') then
    raise exception 'FORBIDDEN';
  end if;
  return query
  select t.id,
         coalesce((
           select jsonb_agg(jsonb_build_object(
             'id', rs.id,
             'name', rs.name,
             'lat', rs.lat,
             'lng', rs.lng,
             'minutes_from_start', ss.minutes_from_start,
             'dwell_minutes', coalesce(ss.dwell_minutes, 0)
           ) order by rs.position)
             from public.route_stops rs
             left join public.service_stops ss
               on ss.service_id = t.service_id and ss.route_stop_id = rs.id
            where rs.route_id = d.route_id
         ), '[]'::jsonb)
    from public.trips t
    join public.service_departures d
      on d.id = t.departure_id and d.service_id = t.service_id and d.company_id = t.company_id
   where t.status = 'in_progress'
     and ((v_role = 'company_admin' and t.company_id = v_company)
       or (v_role in ('platform_admin', 'platform_staff') and (p_company_id is null or t.company_id = p_company_id)));
end
$$;
revoke all on function public.admin_live_trip_schedule(uuid) from public, anon;
grant execute on function public.admin_live_trip_schedule(uuid) to authenticated;

create or replace view public.daily_sales_summary with (security_invoker = true) as
with ticket_totals as (
  select sale_id,
         count(*) as ticket_count,
         count(*) filter (where is_complimentary) as complimentary_count
    from public.sale_tickets
   group by sale_id
)
select s.company_id,
       date_trunc('day', s.created_at at time zone 'America/Argentina/Buenos_Aires') as sale_date,
       s.payment_method,
       count(s.id) as sale_count,
       sum(s.total) as total_amount,
       count(s.id) filter (where s.status = 'refunded') as refunded_count,
       coalesce(sum(tt.complimentary_count), 0)::bigint as complimentary_count
  from public.sales s
  left join ticket_totals tt on tt.sale_id = s.id
 group by s.company_id,
       date_trunc('day', s.created_at at time zone 'America/Argentina/Buenos_Aires'),
       s.payment_method;
grant select on public.daily_sales_summary, public.trip_seat_summary to authenticated;

create or replace function public.platform_sales_report(
  p_from date, p_to date, p_company_id uuid default null
) returns table (
  company_id uuid, company_name text, sale_date date, payment_method public.payment_method,
  sale_count bigint, ticket_count bigint, total_amount numeric, refunded_count bigint,
  complimentary_count bigint
)
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_platform_permission('reports') then raise exception 'FORBIDDEN'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'DATE_RANGE_INVALID: el período debe ser de hasta 367 días';
  end if;
  return query
  with ticket_totals as (
    select st.sale_id, count(*) as ticket_count,
           count(*) filter (where st.is_complimentary) as complimentary_count
      from public.sale_tickets st
     group by st.sale_id
  )
  select s.company_id, c.name, (s.created_at at time zone 'America/Argentina/Buenos_Aires')::date,
         s.payment_method, count(s.id), coalesce(sum(tt.ticket_count), 0)::bigint,
         sum(s.total), count(s.id) filter (where s.status = 'refunded'),
         coalesce(sum(tt.complimentary_count), 0)::bigint
    from public.sales s
    join public.companies c on c.id = s.company_id
    left join ticket_totals tt on tt.sale_id = s.id
   where (s.created_at at time zone 'America/Argentina/Buenos_Aires')::date between p_from and p_to
     and (p_company_id is null or s.company_id = p_company_id)
   group by s.company_id, c.name,
            (s.created_at at time zone 'America/Argentina/Buenos_Aires')::date, s.payment_method
   order by (s.created_at at time zone 'America/Argentina/Buenos_Aires')::date desc,
            c.name, s.payment_method;
end
$$;
revoke all on function public.platform_sales_report(date, date, uuid) from public, anon;
grant execute on function public.platform_sales_report(date, date, uuid) to authenticated;

drop policy sales_insert on public.sales;
drop policy sales_update on public.sales;
drop policy st_insert on public.sale_tickets;
drop policy st_update on public.sale_tickets;
revoke insert, update, delete on public.sales, public.sale_tickets from anon, authenticated;
grant select on public.sales, public.sale_tickets to authenticated;

alter table public.sale_tickets
  add column boarding_event_id uuid unique,
  add column boarded_by uuid references public.profiles (id),
  add column actual_boarding_stop_id uuid references public.route_stops (id),
  add column boarding_override boolean not null default false,
  add column boarding_override_at timestamptz,
  add column boarding_override_by uuid references public.profiles (id);

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
    select 1 from public.service_departures d
     where d.route_id = p_route and d.company_id = v_company
       and exists (select 1 from public.route_stops s where s.route_id = p_route and s.position = p_from_pos)
       and exists (select 1 from public.route_stops s where s.route_id = p_route and s.position = p_to_pos)
  ) then raise exception 'ROUTE_INVALID: el tramo no pertenece a un recorrido de tu empresa'; end if;

  perform 1 from public.companies where id = v_company for update;
  select id into v_id from public.ticket_prices
   where company_id = v_company and route_id = p_route
     and from_pos = p_from_pos and to_pos = p_to_pos
     and seat_class is not distinct from nullif(trim(p_seat_class), '')
   order by created_at desc limit 1 for update;
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
         and (tp.seat_class is null or tp.seat_class = v_seat_class)
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

create or replace function public.cancel_sale_ticket(p_ticket uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ticket public.sale_tickets;
  v_count int;
  v_cancelled int;
  v_sale_status public.sale_status;
begin
  if public.current_user_role() not in ('company_admin', 'seller') then raise exception 'FORBIDDEN'; end if;
  if p_ticket is null or length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'REASON_REQUIRED: el motivo debe tener al menos 5 caracteres';
  end if;
  select * into v_ticket from public.sale_tickets
   where id = p_ticket and company_id = public.current_company_id()
   for update;
  if not found then raise exception 'TICKET_NOT_FOUND'; end if;
  if v_ticket.status = 'cancelled' then raise exception 'ALREADY_CANCELLED'; end if;
  if v_ticket.status = 'boarded' then raise exception 'ALREADY_BOARDED'; end if;
  perform 1 from public.sales where id = v_ticket.sale_id for update;

  update public.sale_tickets set status = 'cancelled', cancelled_at = clock_timestamp(),
    cancelled_by = auth.uid(), cancel_reason = trim(p_reason)
   where id = v_ticket.id;

  select count(*), count(*) filter (where status = 'cancelled')
    into v_count, v_cancelled from public.sale_tickets where sale_id = v_ticket.sale_id;
  v_sale_status := case when v_cancelled = v_count then 'refunded'::public.sale_status
                        when v_cancelled > 0 then 'partial_refund'::public.sale_status
                        else 'completed'::public.sale_status end;
  update public.sales set status = v_sale_status,
    refunded_at = case when v_cancelled > 0 then clock_timestamp() else null end,
    refunded_by = case when v_cancelled > 0 then auth.uid() else null end
   where id = v_ticket.sale_id;
  return jsonb_build_object('ok', true, 'ticket_id', v_ticket.id, 'sale_status', v_sale_status);
end
$$;
revoke all on function public.cancel_sale_ticket(uuid, text) from public, anon;
grant execute on function public.cancel_sale_ticket(uuid, text) to authenticated;

create or replace function public._commit_sale_ticket_boarding(
  p_trip uuid, p_code text, p_event uuid, p_override boolean, p_expected_stop uuid,
  p_lat double precision, p_lng double precision, p_accuracy_m double precision, p_fix_at timestamptz
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_trip public.trips;
  v_ticket public.sale_tickets;
  v_route uuid;
  v_stop uuid;
  v_stop_name text;
  v_distance double precision;
  v_second_distance double precision;
  v_actual_pos int;
  v_board_pos int;
  v_alight_pos int;
  v_counts jsonb;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_event is null then raise exception 'EVENT_REQUIRED'; end if;
  if p_code is null or length(trim(p_code)) < 8 then
    return jsonb_build_object('ok', false, 'code', 'INVALID_TICKET', 'title', 'QR inválido', 'detail', 'El código no corresponde a un pasaje.');
  end if;

  select * into v_trip from public.trips
   where id = p_trip and company_id = public.current_company_id() and driver_id = auth.uid()
   for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'in_progress' then raise exception 'INVALID_STATE: el viaje no está en curso'; end if;
  select d.route_id into v_route from public.service_departures d
   where d.id = v_trip.departure_id and d.service_id = v_trip.service_id and d.company_id = v_trip.company_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  if p_lat is null or p_lng is null or p_lat::text in ('NaN','Infinity','-Infinity')
     or p_lng::text in ('NaN','Infinity','-Infinity') or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or p_accuracy_m is null or p_accuracy_m::text in ('NaN','Infinity','-Infinity')
     or p_accuracy_m <= 0 or p_accuracy_m > 50 or p_fix_at is null
     or p_fix_at > clock_timestamp() + interval '5 seconds'
     or p_fix_at < clock_timestamp() - interval '15 seconds' then
    return jsonb_build_object('ok', false, 'code', 'GPS_REQUIRED', 'title', 'No se pudo verificar la parada',
      'detail', 'Se necesita una ubicación GPS reciente y precisa (máximo 50 m).');
  end if;
  if exists (select 1 from public.route_stops where route_id = v_route and (lat is null or lng is null)) then
    return jsonb_build_object('ok', false, 'code', 'GPS_STOPS_UNCONFIGURED', 'title', 'Faltan coordenadas del recorrido',
      'detail', 'Todas las paradas deben tener coordenadas para verificar el ascenso por GPS.');
  end if;

  with candidates as (
    select rs.id, rs.name, rs.position,
      6371000::double precision * 2 * asin(sqrt(least(1::double precision,
        power(sin(radians(rs.lat::double precision - p_lat) / 2), 2)
        + cos(radians(p_lat)) * cos(radians(rs.lat::double precision))
          * power(sin(radians(rs.lng::double precision - p_lng) / 2), 2)
      ))) as distance_m
    from public.route_stops rs where rs.route_id = v_route
  ), ranked as (
    select id, name, position, distance_m,
      lead(distance_m) over (order by distance_m, position) as second_distance_m
    from candidates
  )
  select id, name, position, distance_m, second_distance_m
    into v_stop, v_stop_name, v_actual_pos, v_distance, v_second_distance
    from ranked order by distance_m, position limit 1;
  if not found then return jsonb_build_object('ok', false, 'code', 'GPS_STOPS_UNCONFIGURED',
    'title', 'No se pudieron verificar las paradas', 'detail', 'El recorrido no tiene paradas geolocalizadas.'); end if;
  if v_distance + p_accuracy_m > 80 then
    return jsonb_build_object('ok', false, 'code', 'GPS_NOT_AT_STOP', 'title', 'La unidad no está junto a una parada',
      'detail', 'Acercá la unidad a una parada antes de escanear.');
  end if;
  if v_second_distance is not null and v_second_distance - v_distance <= p_accuracy_m then
    return jsonb_build_object('ok', false, 'code', 'GPS_STOP_AMBIGUOUS', 'title', 'No se pudo distinguir la parada',
      'detail', 'Esperá una ubicación GPS más precisa.');
  end if;
  if p_expected_stop is not null and p_expected_stop <> v_stop then
    return jsonb_build_object('ok', false, 'code', 'GPS_STOP_CHANGED', 'actual_stop_id', v_stop,
      'actual_stop', v_stop_name, 'title', 'La ubicación cambió', 'detail', 'Volvé a escanear el pasaje.');
  end if;

  select * into v_ticket from public.sale_tickets where qr_code = trim(p_code) for update;
  if not found or v_ticket.company_id <> v_trip.company_id then
    return jsonb_build_object('ok', false, 'code', 'INVALID_TICKET', 'title', 'QR inválido', 'detail', 'No se encontró el pasaje.');
  end if;
  if v_ticket.trip_id <> v_trip.id then return jsonb_build_object('ok', false, 'code', 'OTHER_TRIP',
    'title', 'Pasaje de otro viaje', 'detail', 'Este QR no pertenece al viaje actual.'); end if;
  if v_ticket.status = 'cancelled' then return jsonb_build_object('ok', false, 'code', 'CANCELLED',
    'title', 'Pasaje anulado', 'detail', 'El pasaje fue anulado y no puede abordar.'); end if;
  if v_ticket.status = 'boarded' then
    if v_ticket.boarding_event_id = p_event then
      return jsonb_build_object('ok', true, 'code', v_ticket.qr_code, 'title', 'Ascenso ya registrado',
        'detail', 'Esta lectura ya había sido procesada.', 'boarding_override', v_ticket.boarding_override);
    end if;
    return jsonb_build_object('ok', false, 'code', 'ALREADY_BOARDED', 'title', 'QR ya utilizado',
      'detail', 'Este pasaje ya fue validado.');
  end if;

  select position into v_board_pos from public.route_stops where id = v_ticket.from_stop_id and route_id = v_route;
  select position into v_alight_pos from public.route_stops where id = v_ticket.to_stop_id and route_id = v_route;
  if v_board_pos is null or v_alight_pos is null or v_board_pos >= v_alight_pos then
    return jsonb_build_object('ok', false, 'code', 'TICKET_ROUTE_INVALID', 'title', 'Pasaje inválido',
      'detail', 'El tramo del pasaje no corresponde al recorrido.');
  end if;
  if v_actual_pos >= v_alight_pos then return jsonb_build_object('ok', false, 'code', 'PAST_ALIGHTING_STOP',
    'title', 'Ascenso no permitido', 'detail', 'La unidad ya pasó la parada de descenso.'); end if;
  if v_actual_pos < v_board_pos then return jsonb_build_object('ok', false, 'code', 'BOARDING_STOP_MISMATCH',
    'title', 'Ascenso no permitido', 'detail', 'El pasaje corresponde a una parada posterior.'); end if;
  if v_actual_pos <> v_board_pos and not p_override then
    return jsonb_build_object('ok', false, 'code', 'BOARDING_STOP_MISMATCH', 'can_override', true,
      'actual_stop_id', v_stop, 'boarding_stop', (select name from public.route_stops where id = v_ticket.from_stop_id),
      'actual_stop', v_stop_name, 'title', 'El pasaje indica otro punto de ascenso',
      'detail', format('Autorizá el ascenso en %s solo si verificaste la identidad del pasajero.', v_stop_name));
  end if;
  if p_override and (v_actual_pos = v_board_pos or v_actual_pos < v_board_pos) then
    return jsonb_build_object('ok', false, 'code', 'OVERRIDE_NOT_NEEDED', 'title', 'No se puede autorizar',
      'detail', 'La parada actual no requiere autorización.');
  end if;

  v_counts := public.register_count(v_trip.id, 'board', 1, v_stop, p_event);
  update public.sale_tickets set status = 'boarded', boarded_at = clock_timestamp(),
    boarded_by = auth.uid(), actual_boarding_stop_id = v_stop, boarding_event_id = p_event,
    boarding_override = p_override,
    boarding_override_at = case when p_override then clock_timestamp() else null end,
    boarding_override_by = case when p_override then auth.uid() else null end
   where id = v_ticket.id;
  return v_counts || jsonb_build_object('ok', true, 'code', v_ticket.qr_code,
    'title', case when p_override then 'Ascenso autorizado' else 'Pasaje validado' end,
    'actual_stop_id', v_stop, 'actual_stop', v_stop_name,
    'detail', case when p_override then 'El conductor autorizó el ascenso.' else 'Ascenso registrado.' end,
    'boarding_override', p_override);
end
$$;
revoke all on function public._commit_sale_ticket_boarding(uuid, text, uuid, boolean, uuid, double precision, double precision, double precision, timestamptz) from public, anon, authenticated;

create or replace function public.scan_ticket(
  p_trip uuid, p_code text, p_event uuid, p_lat double precision, p_lng double precision,
  p_accuracy_m double precision, p_fix_at timestamptz
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.sale_tickets where qr_code = trim(p_code) and trip_id = p_trip) then
    return public._commit_sale_ticket_boarding(p_trip, p_code, p_event, false, null, p_lat, p_lng, p_accuracy_m, p_fix_at);
  end if;
  return public._commit_test_ticket_boarding(p_trip, p_code, p_event, false, null, p_lat, p_lng, p_accuracy_m, p_fix_at);
end
$$;
revoke all on function public.scan_ticket(uuid, text, uuid, double precision, double precision, double precision, timestamptz) from public, anon, authenticated;
grant execute on function public.scan_ticket(uuid, text, uuid, double precision, double precision, double precision, timestamptz) to authenticated;

create or replace function public.override_ticket_boarding(
  p_trip uuid, p_code text, p_stop uuid, p_event uuid, p_lat double precision, p_lng double precision,
  p_accuracy_m double precision, p_fix_at timestamptz
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.sale_tickets where qr_code = trim(p_code) and trip_id = p_trip) then
    return public._commit_sale_ticket_boarding(p_trip, p_code, p_event, true, p_stop, p_lat, p_lng, p_accuracy_m, p_fix_at);
  end if;
  return public._commit_test_ticket_boarding(p_trip, p_code, p_event, true, p_stop, p_lat, p_lng, p_accuracy_m, p_fix_at);
end
$$;
revoke all on function public.override_ticket_boarding(uuid, text, uuid, uuid, double precision, double precision, double precision, timestamptz) from public, anon, authenticated;
grant execute on function public.override_ticket_boarding(uuid, text, uuid, uuid, double precision, double precision, double precision, timestamptz) to authenticated;

create or replace function public.admin_live_trips(p_company_id uuid default null)
returns table (
  trip_id uuid, company_id uuid, company_name text, service_code text, service_date date,
  scheduled_departure timestamptz, started_at timestamptz, route_id uuid, route_name text,
  route_path jsonb, vehicle_number text, vehicle_plate text, driver_name text, latitude double precision,
  longitude double precision, accuracy_m real, heading real, location_at timestamptz
)
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  v_company uuid := public.current_company_id();
begin
  if v_role = 'company_admin' then
    if p_company_id is not null and p_company_id is distinct from v_company then raise exception 'FORBIDDEN'; end if;
  elsif not public.has_platform_permission('gps') then
    raise exception 'FORBIDDEN';
  end if;
  return query
  select t.id, t.company_id, c.name, s.code, t.service_date, t.scheduled_departure, t.started_at,
         r.id, r.name, r.path, v.internal_number, v.plate, p.full_name,
         live.latitude, live.longitude, live.accuracy_m, live.heading, live.recorded_at
    from public.trips t
    join public.companies c on c.id = t.company_id
    join public.services s on s.id = t.service_id
    join public.service_departures d on d.id = t.departure_id
    join public.routes r on r.id = d.route_id
    left join public.vehicles v on v.id = t.vehicle_id
    left join public.profiles p on p.id = t.driver_id
    left join public.trip_live_positions live on live.trip_id = t.id
   where t.status = 'in_progress'
     and ((v_role = 'company_admin' and t.company_id = v_company)
       or (v_role in ('platform_admin', 'platform_staff') and (p_company_id is null or t.company_id = p_company_id)))
   order by c.name, s.code, t.scheduled_departure;
end
$$;
revoke all on function public.admin_live_trips(uuid) from public, anon;
grant execute on function public.admin_live_trips(uuid) to authenticated;

notify pgrst, 'reload schema';
