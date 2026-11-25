-- Abonos por tipo de día: cada abono vale solo para los tipos de día que se tilden (H/S/D/F).
--  * pass_products.day_types: lo que define la empresa; passes y pass_checkout_orders guardan una copia al vender/comprar.
--  * Los abonos existentes valen todos los días.
--  * Usar un abono en un viaje de otro tipo de día falla con PASS_DAY_MISMATCH.
alter table public.pass_products add column day_types text[] not null default array['weekday','saturday','sunday','holiday']
  check (cardinality(day_types) > 0 and day_types <@ array['weekday','saturday','sunday','holiday']);
alter table public.passes add column day_types text[] not null default array['weekday','saturday','sunday','holiday']
  check (cardinality(day_types) > 0 and day_types <@ array['weekday','saturday','sunday','holiday']);
alter table public.pass_checkout_orders add column day_types text[] not null default array['weekday','saturday','sunday','holiday']
  check (cardinality(day_types) > 0 and day_types <@ array['weekday','saturday','sunday','holiday']);

-- orden fijo y sin repetidos, para que 'S,D' y 'D,S' cuenten como el mismo abono
create function public._pass_products_normalize_days() returns trigger
language plpgsql as $$
begin
  new.day_types := array(select distinct x from unnest(new.day_types) x order by x);
  return new;
end $$;
create trigger pass_products_normalize_days before insert or update of day_types on public.pass_products
  for each row execute function public._pass_products_normalize_days();

drop index public.pass_products_unique;
create unique index pass_products_unique
  on public.pass_products (company_id, place_a, place_b, coalesce(seat_class, ''), trips, day_types) where active;

-- " · días H·S·D" cuando no vale todos los días (vacío si vale los cuatro)
create function public.pass_days_short(p_days text[]) returns text
language sql immutable as $$
  select case when p_days @> array['weekday','saturday','sunday','holiday'] then ''
    else ' · días ' || concat_ws('·',
      case when 'weekday' = any (p_days) then 'H' end, case when 'saturday' = any (p_days) then 'S' end,
      case when 'sunday' = any (p_days) then 'D' end, case when 'holiday' = any (p_days) then 'F' end) end
$$;
grant execute on function public.pass_days_short(text[]) to anon, authenticated, service_role;

create or replace function public.pass_sell(
  p_product uuid, p_holder_dni text, p_holder_name text, p_holder_email text, p_payment_method public.payment_method
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_user_role()::text;
  v_prod public.pass_products;
  v_dni text := regexp_replace(trim(coalesce(p_holder_dni, '')), '[^0-9]', '', 'g');
  v_name text := trim(coalesce(p_holder_name, ''));
  v_email text := nullif(lower(trim(coalesce(p_holder_email, ''))), '');
  v_id uuid;
  v_expires timestamptz;
begin
  if v_role not in ('company_admin', 'seller') then raise exception 'FORBIDDEN'; end if;
  if p_payment_method not in ('cash', 'transfer', 'debit', 'credit') then
    raise exception 'PAYMENT_INVALID: forma de pago no habilitada';
  end if;
  select * into v_prod from public.pass_products
   where id = p_product and company_id = public.current_company_id() and active;
  if not found then raise exception 'PRODUCT_NOT_FOUND: el abono no existe o está pausado'; end if;
  if not public.company_feature_enabled(v_prod.company_id, 'fares') then
    raise exception 'FEATURE_BLOCKED: las tarifas, ventas y taquilla no están habilitadas para esta empresa';
  end if;
  if v_dni !~ '^[0-9]{7,10}$' or length(v_name) < 2 or length(v_name) > 150 then
    raise exception 'PASSENGER_INVALID: cargá nombre y apellido y un DNI válido (7 a 10 números)';
  end if;
  if v_email is not null and (v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(v_email) > 200) then
    raise exception 'PASSENGER_INVALID: el correo no es válido';
  end if;
  v_expires := clock_timestamp() + make_interval(days => v_prod.valid_days);
  insert into public.passes (company_id, product_id, place_a, place_b, seat_class, holder_dni, holder_name, holder_email,
                             trips_total, trips_left, price, payment_method, sold_by, expires_at, day_types)
  values (v_prod.company_id, v_prod.id, v_prod.place_a, v_prod.place_b, v_prod.seat_class, v_dni, v_name, v_email,
          v_prod.trips, v_prod.trips, v_prod.price, p_payment_method, auth.uid(), v_expires, v_prod.day_types)
  returning id into v_id;
  insert into public.pass_movements (pass_id, kind, delta) values (v_id, 'sale', v_prod.trips);
  return jsonb_build_object('pass_id', v_id, 'trips', v_prod.trips, 'price', v_prod.price, 'expires_at', v_expires);
end $$;

create or replace function public._pass_redeem(
  p_pass uuid, p_trip uuid, p_from uuid, p_to uuid, p_label text, p_channel text, p_seller uuid
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_pass public.passes;
  v_trip public.trips;
  v_route uuid;
  v_s record;
  v_pa uuid;
  v_pb uuid;
  v_sale uuid;
  v_ticket uuid;
  v_qr text := gen_random_uuid()::text;
begin
  select * into v_pass from public.passes where id = p_pass for update;
  if not found or v_pass.status <> 'active' then raise exception 'PASS_NOT_FOUND: el abono no existe o fue dado de baja'; end if;
  select * into v_trip from public.trips where id = p_trip and company_id = v_pass.company_id for update;
  if not found then raise exception 'TRIP_NOT_FOUND'; end if;
  if v_trip.status not in ('scheduled', 'in_progress') then raise exception 'TRIP_CLOSED'; end if;
  if v_pass.trips_left < 1 then raise exception 'PASS_EMPTY: el abono no tiene viajes disponibles'; end if;
  if clock_timestamp() >= v_pass.expires_at then raise exception 'PASS_EXPIRED: el abono está vencido'; end if;
  if v_trip.scheduled_departure > v_pass.expires_at then
    raise exception 'PASS_EXPIRES_BEFORE_TRIP: el abono vence antes de la salida de este viaje';
  end if;
  select d.route_id into v_route from public.service_departures d
   where d.id = v_trip.departure_id and d.service_id = v_trip.service_id and d.company_id = v_trip.company_id;
  if not found then raise exception 'ROUTE_INVALID'; end if;
  if not (v_trip.day_type = any (v_pass.day_types)) then
    raise exception 'PASS_DAY_MISMATCH: el abono no vale para este tipo de día';
  end if;

  select * into v_s from public._taquilla_seat(p_trip, v_route, v_trip.layout_id,
    jsonb_build_object('seat_label', p_label, 'from_stop_id', p_from, 'to_stop_id', p_to));

  select place_id into v_pa from public.route_stops where id = p_from;
  select place_id into v_pb from public.route_stops where id = p_to;
  if v_pa is null or v_pb is null
     or not ((v_pa = v_pass.place_a and v_pb = v_pass.place_b) or (v_pa = v_pass.place_b and v_pb = v_pass.place_a)) then
    raise exception 'PASS_ROUTE_MISMATCH: el abono no vale para este tramo';
  end if;
  if v_pass.seat_class is not null
     and public.normalize_seat_class(v_s.o_class) is distinct from public.normalize_seat_class(v_pass.seat_class) then
    raise exception 'PASS_CLASS_MISMATCH: el abono no vale para esta clase de asiento';
  end if;

  insert into public.sales (company_id, seller_id, trip_id, payment_method, total, notes, channel)
  values (v_pass.company_id, p_seller, p_trip, 'pass', 0, 'Pasaje con abono', p_channel)
  returning id into v_sale;
  insert into public.sale_tickets (
    company_id, sale_id, trip_id, seat_label, layout_cell_id, from_stop_id, to_stop_id,
    passenger_name, passenger_dni, passenger_email, passenger_phone, price, qr_code, ticket_type, status, pass_id
  ) values (
    v_pass.company_id, v_sale, p_trip, v_s.o_label, v_s.o_cell, v_s.o_from, v_s.o_to,
    v_pass.holder_name, v_pass.holder_dni, coalesce(v_pass.holder_email, 'abono@pasajeros.ar'), '0000000', 0, v_qr,
    'regular', 'valid', v_pass.id
  ) returning id into v_ticket;
  update public.passes set trips_left = trips_left - 1 where id = v_pass.id;
  insert into public.pass_movements (pass_id, kind, delta, ticket_id) values (v_pass.id, 'use', -1, v_ticket);
  return jsonb_build_object('sale_id', v_sale, 'ticket_id', v_ticket, 'qr_code', v_qr, 'seat_label', v_s.o_label,
    'trips_left', v_pass.trips_left - 1, 'expires_at', v_pass.expires_at);
end $$;

create or replace function public.begin_pass_checkout(p_user uuid, p_product uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_prod public.pass_products;
  v_profile public.passenger_profiles;
  v_order uuid;
  v_expires timestamptz;
  v_title text;
begin
  if auth.role() <> 'service_role' then raise exception 'FORBIDDEN'; end if;
  select * into v_profile from public.passenger_profiles where user_id = p_user;
  if not found then raise exception 'PASSENGER_PROFILE_REQUIRED'; end if;
  select * into v_prod from public.pass_products where id = p_product and active and price > 0;
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;
  if not exists (select 1 from public.companies where id = v_prod.company_id and active)
     or not public.company_feature_enabled(v_prod.company_id, 'web')
     or not public.company_feature_enabled(v_prod.company_id, 'fares') then
    raise exception 'TRIP_UNAVAILABLE';
  end if;
  if not exists (select 1 from public.mp_company_connections where company_id = v_prod.company_id and active and test_mode) then
    raise exception 'MERCADOPAGO_NOT_CONNECTED';
  end if;
  insert into public.pass_checkout_orders (company_id, mp_connection_id, passenger_user_id, product_id, place_a, place_b, seat_class, trips, valid_days, price, day_types)
  values (v_prod.company_id, v_prod.company_id, p_user, v_prod.id, v_prod.place_a, v_prod.place_b, v_prod.seat_class, v_prod.trips, v_prod.valid_days, v_prod.price, v_prod.day_types)
  returning id, expires_at into v_order, v_expires;
  select 'Abono ' || v_prod.trips || ' viajes · ' || pa.name || ' - ' || pb.name || coalesce(' · ' || v_prod.seat_class, '') || public.pass_days_short(v_prod.day_types)
    into v_title from public.places pa, public.places pb where pa.id = v_prod.place_a and pb.id = v_prod.place_b;
  return jsonb_build_object('order_id', v_order, 'company_id', v_prod.company_id, 'price', v_prod.price, 'title', v_title, 'expires_at', v_expires);
end $$;

create or replace function public.finalize_pass_checkout(p_order uuid, p_payment_id text, p_amount numeric, p_currency text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_order public.pass_checkout_orders;
  v_profile public.passenger_profiles;
  v_pass uuid;
  v_expires timestamptz;
begin
  if auth.role() <> 'service_role' then raise exception 'FORBIDDEN'; end if;
  select * into v_order from public.pass_checkout_orders where id = p_order for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.status = 'approved' then
    if v_order.mp_payment_id <> p_payment_id then raise exception 'PAYMENT_ID_CONFLICT'; end if;
    return jsonb_build_object('status', 'approved', 'pass_id', v_order.pass_id);
  end if;
  if p_payment_id is null or p_amount <> v_order.price or p_currency <> 'ARS' then raise exception 'PAYMENT_AMOUNT_INVALID'; end if;
  if v_order.status = 'cancelled' or v_order.status = 'refund_required' then
    update public.pass_checkout_orders set status = 'refund_required', mp_payment_id = p_payment_id where id = v_order.id;
    return jsonb_build_object('status', 'refund_required');
  end if;
  -- un pago aprobado se entrega aunque haya pasado el plazo de espera (no compite por asientos)
  select * into v_profile from public.passenger_profiles where user_id = v_order.passenger_user_id;
  if not found then
    update public.pass_checkout_orders set status = 'refund_required', mp_payment_id = p_payment_id where id = v_order.id;
    return jsonb_build_object('status', 'refund_required');
  end if;
  v_expires := clock_timestamp() + make_interval(days => v_order.valid_days);
  insert into public.passes (company_id, product_id, place_a, place_b, seat_class, holder_dni, holder_name, holder_email,
                             trips_total, trips_left, price, payment_method, sold_by, expires_at, day_types)
  values (v_order.company_id, v_order.product_id, v_order.place_a, v_order.place_b, v_order.seat_class, v_profile.dni,
          trim(v_profile.first_name || ' ' || v_profile.last_name), v_profile.email,
          v_order.trips, v_order.trips, v_order.price, 'mp', null, v_expires, v_order.day_types)
  returning id into v_pass;
  insert into public.pass_movements (pass_id, kind, delta) values (v_pass, 'sale', v_order.trips);
  update public.pass_checkout_orders set status = 'approved', mp_payment_id = p_payment_id, pass_id = v_pass where id = v_order.id;
  return jsonb_build_object('status', 'approved', 'pass_id', v_pass);
end $$;

drop function public.passenger_my_passes();
create function public.passenger_my_passes()
returns table (pass_id uuid, company_id uuid, company_name text, place_a uuid, place_b uuid, place_a_name text, place_b_name text,
               seat_class text, trips_total int, trips_left int, purchased_at timestamptz, expires_at timestamptz,
               status text, usable boolean, day_types text[])
language sql stable security definer set search_path = public as $$
  select p.id, p.company_id, c.name, p.place_a, p.place_b, pa.name, pb.name, p.seat_class, p.trips_total, p.trips_left,
         p.purchased_at, p.expires_at, p.status,
         (p.status = 'active' and p.trips_left > 0 and p.expires_at > clock_timestamp()), p.day_types
    from public.passes p
    join public.passenger_profiles pp on pp.dni = p.holder_dni and pp.user_id = auth.uid()
    join public.companies c on c.id = p.company_id
    join public.places pa on pa.id = p.place_a
    join public.places pb on pb.id = p.place_b
   order by (p.status = 'active' and p.trips_left > 0 and p.expires_at > clock_timestamp()) desc, p.expires_at desc;
$$;
revoke all on function public.passenger_my_passes() from public, anon;
grant execute on function public.passenger_my_passes() to authenticated;

drop function public.passenger_pass_catalog();
create function public.passenger_pass_catalog()
returns table (product_id uuid, company_id uuid, company_name text, logo_path text, place_a_name text, place_b_name text,
               seat_class text, trips int, price numeric, valid_days int, day_types text[])
language sql stable security definer set search_path = public as $$
  select p.id, p.company_id, c.name, c.logo_path, pa.name, pb.name, p.seat_class, p.trips, p.price, p.valid_days, p.day_types
    from public.pass_products p
    join public.companies c on c.id = p.company_id and c.active
    join public.places pa on pa.id = p.place_a
    join public.places pb on pb.id = p.place_b
   where p.active and p.price > 0
     and public.company_feature_enabled(p.company_id, 'web')
     and public.company_feature_enabled(p.company_id, 'fares')
     and exists (select 1 from public.mp_company_connections m where m.company_id = p.company_id and m.active and m.test_mode)
   order by c.name, pa.name, pb.name, p.seat_class nulls first, p.trips;
$$;
revoke all on function public.passenger_pass_catalog() from public;
grant execute on function public.passenger_pass_catalog() to anon, authenticated;

drop function public.staff_find_passes(text, boolean, int);
create function public.staff_find_passes(p_dni text default null, p_only_active boolean default false, p_limit int default 100)
returns table (pass_id uuid, holder_name text, holder_dni text, place_a_name text, place_b_name text, seat_class text,
               trips_total int, trips_left int, price numeric, purchased_at timestamptz, expires_at timestamptz, status text, expired boolean, day_types text[])
language plpgsql stable security definer set search_path = public as $$
declare
  v_dni text := nullif(regexp_replace(trim(coalesce(p_dni, '')), '[^0-9]', '', 'g'), '');
begin
  if public.current_user_role()::text not in ('company_admin', 'seller', 'support') then raise exception 'FORBIDDEN'; end if;
  return query
    select p.id, p.holder_name, p.holder_dni, pa.name, pb.name, p.seat_class, p.trips_total, p.trips_left, p.price,
           p.purchased_at, p.expires_at, p.status, p.expires_at <= clock_timestamp(), p.day_types
      from public.passes p
      join public.places pa on pa.id = p.place_a
      join public.places pb on pb.id = p.place_b
     where p.company_id = public.current_company_id()
       and (v_dni is null or p.holder_dni = v_dni)
       and (not p_only_active or (p.status = 'active' and p.trips_left > 0 and p.expires_at > clock_timestamp()))
     order by p.purchased_at desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500);
end $$;
revoke all on function public.staff_find_passes(text, boolean, int) from public, anon;
grant execute on function public.staff_find_passes(text, boolean, int) to authenticated;

-- tipo de día de un viaje publicado (la web lo usa para ofrecer solo los abonos que valen ese día)
create function public.trip_day_type(p_trip uuid) returns text
language sql stable security definer set search_path = public as $$
  select day_type from public.trips where id = p_trip and published_at is not null
$$;
revoke all on function public.trip_day_type(uuid) from public;
grant execute on function public.trip_day_type(uuid) to anon, authenticated;
notify pgrst, 'reload schema';
