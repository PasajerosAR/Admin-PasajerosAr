-- 0052: abonos (paquetes de viajes por tramo).
-- * pass_products: lo que la empresa ofrece (tramo entre dos localidades, cantidad de viajes, precio, validez).
-- * passes: abonos vendidos (saldo de viajes y vencimiento); pass_movements: libro de movimientos.
-- * Usar un abono emite un pasaje común (mismo QR, precio 0, forma de pago 'pass'); el conductor no cambia.
-- * Cancelar ese pasaje con 2 horas o más de anticipación devuelve el viaje al saldo.
-- El abono vale en ambos sentidos entre las dos localidades, es personal (por DNI) y vence a los N días de la compra.

alter type public.payment_method add value if not exists 'pass';

create table public.pass_products (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id),
  place_a     uuid not null references public.places (id),
  place_b     uuid not null references public.places (id),
  seat_class  text,                                           -- null = cualquier clase de asiento
  trips       int  not null check (trips between 1 and 200),
  price       numeric(10, 2) not null check (price >= 0),
  valid_days  int  not null default 30 check (valid_days between 1 and 365),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  constraint pass_products_pair check (place_a::text < place_b::text)   -- par ordenado: A-B es lo mismo que B-A
);
create unique index pass_products_unique
  on public.pass_products (company_id, place_a, place_b, coalesce(seat_class, ''), trips) where active;
create index pass_products_company_idx on public.pass_products (company_id);
alter table public.pass_products enable row level security;
create policy pass_products_select on public.pass_products for select to authenticated
  using (company_id = public.current_company_id() and public.current_user_role()::text in ('company_admin', 'seller', 'support'));
create policy pass_products_insert on public.pass_products for insert to authenticated
  with check (company_id = public.current_company_id() and public.is_company_admin());
create policy pass_products_update on public.pass_products for update to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin())
  with check (company_id = public.current_company_id() and public.is_company_admin());
create policy pass_products_delete on public.pass_products for delete to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin());
grant select, insert, update, delete on public.pass_products to authenticated;

create table public.passes (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies (id),
  product_id    uuid references public.pass_products (id),
  place_a       uuid not null references public.places (id),
  place_b       uuid not null references public.places (id),
  seat_class    text,
  holder_dni    text not null check (holder_dni ~ '^[0-9]{7,10}$'),
  holder_name   text not null check (length(trim(holder_name)) between 2 and 150),
  holder_email  text check (holder_email is null or holder_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  trips_total   int  not null check (trips_total >= 1),
  trips_left    int  not null check (trips_left >= 0),
  price         numeric(10, 2) not null check (price >= 0),
  payment_method public.payment_method not null,
  sold_by       uuid references public.profiles (id),
  purchased_at  timestamptz not null default now(),
  expires_at    timestamptz not null,
  status        text not null default 'active' check (status in ('active', 'cancelled')),
  cancelled_at  timestamptz,
  cancel_reason text,
  constraint passes_left_le_total check (trips_left <= trips_total)
);
create index passes_company_dni_idx on public.passes (company_id, holder_dni);
create index passes_dni_idx on public.passes (holder_dni);
alter table public.passes enable row level security;     -- sin políticas: solo se accede por las funciones de abajo

create table public.pass_movements (
  id          uuid primary key default gen_random_uuid(),
  pass_id     uuid not null references public.passes (id) on delete cascade,
  kind        text not null check (kind in ('sale', 'use', 'refund', 'forfeit', 'void')),
  delta       int  not null,
  ticket_id   uuid references public.sale_tickets (id),
  created_at  timestamptz not null default now()
);
create index pass_movements_pass_idx on public.pass_movements (pass_id, created_at);
alter table public.pass_movements enable row level security;

alter table public.sale_tickets add column pass_id uuid references public.passes (id);
create index sale_tickets_pass_idx on public.sale_tickets (pass_id) where pass_id is not null;

-- un pasaje de abono lo puede cancelar el propio pasajero (no está en profiles): cancelled_by puede quedar vacío solo en ese caso
alter table public.sale_tickets drop constraint cancelled_state_check;
alter table public.sale_tickets add constraint cancelled_state_check check (
  (status <> 'cancelled' and cancelled_at is null and cancelled_by is null and cancel_reason is null)
  or (status = 'cancelled' and cancelled_at is not null and cancel_reason is not null
      and (cancelled_by is not null or pass_id is not null))
);

-- ---------------------------------------------------------------- admin: pares con tarifa (base para generar abonos)
create function public.pass_fare_pairs()
returns table (place_a uuid, place_b uuid, place_a_name text, place_b_name text, seat_class text, base_price numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  return query
    select least(fs.place_id::text, ts.place_id::text)::uuid, greatest(fs.place_id::text, ts.place_id::text)::uuid,
           (select name from public.places where id = least(fs.place_id::text, ts.place_id::text)::uuid),
           (select name from public.places where id = greatest(fs.place_id::text, ts.place_id::text)::uuid),
           tp.seat_class, max(tp.price)::numeric
      from public.ticket_prices tp
      join public.route_stops fs on fs.route_id = tp.route_id and fs.position = tp.from_pos
      join public.route_stops ts on ts.route_id = tp.route_id and ts.position = tp.to_pos
     where tp.company_id = public.current_company_id() and tp.active
       and fs.place_id is not null and ts.place_id is not null and fs.place_id <> ts.place_id
     group by 1, 2, 3, 4, tp.seat_class
     order by 3, 4, tp.seat_class nulls first;
end $$;
revoke all on function public.pass_fare_pairs() from public, anon;
grant execute on function public.pass_fare_pairs() to authenticated;

-- ---------------------------------------------------------------- venta en ventanilla
create function public.pass_sell(
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
                             trips_total, trips_left, price, payment_method, sold_by, expires_at)
  values (v_prod.company_id, v_prod.id, v_prod.place_a, v_prod.place_b, v_prod.seat_class, v_dni, v_name, v_email,
          v_prod.trips, v_prod.trips, v_prod.price, p_payment_method, auth.uid(), v_expires)
  returning id into v_id;
  insert into public.pass_movements (pass_id, kind, delta) values (v_id, 'sale', v_prod.trips);
  return jsonb_build_object('pass_id', v_id, 'trips', v_prod.trips, 'price', v_prod.price, 'expires_at', v_expires);
end $$;
revoke all on function public.pass_sell(uuid, text, text, text, public.payment_method) from public, anon;
grant execute on function public.pass_sell(uuid, text, text, text, public.payment_method) to authenticated;

-- ---------------------------------------------------------------- consulta (empresa)
create function public.staff_find_passes(p_dni text default null, p_only_active boolean default false, p_limit int default 100)
returns table (pass_id uuid, holder_name text, holder_dni text, place_a_name text, place_b_name text, seat_class text,
               trips_total int, trips_left int, price numeric, purchased_at timestamptz, expires_at timestamptz, status text, expired boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_dni text := nullif(regexp_replace(trim(coalesce(p_dni, '')), '[^0-9]', '', 'g'), '');
begin
  if public.current_user_role()::text not in ('company_admin', 'seller', 'support') then raise exception 'FORBIDDEN'; end if;
  return query
    select p.id, p.holder_name, p.holder_dni, pa.name, pb.name, p.seat_class, p.trips_total, p.trips_left, p.price,
           p.purchased_at, p.expires_at, p.status, p.expires_at <= clock_timestamp()
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

-- abonos vendidos por forma de pago (se suma al cierre de caja)
create function public.pass_cash_close(p_from timestamptz, p_to timestamptz, p_seller uuid default null)
returns table (seller_id uuid, seller_name text, payment_method public.payment_method, passes bigint, collected numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  v_role text := public.current_user_role()::text;
  v_seller uuid := p_seller;
begin
  if v_role not in ('company_admin', 'seller') then raise exception 'FORBIDDEN'; end if;
  if v_role = 'seller' then v_seller := auth.uid(); end if;
  return query
    select p.sold_by, pr.full_name, p.payment_method, count(*), coalesce(sum(p.price), 0)::numeric
      from public.passes p join public.profiles pr on pr.id = p.sold_by
     where p.company_id = public.current_company_id() and p.purchased_at >= p_from and p.purchased_at < p_to
       and (v_seller is null or p.sold_by = v_seller)
     group by p.sold_by, pr.full_name, p.payment_method
     order by pr.full_name, p.payment_method;
end $$;
revoke all on function public.pass_cash_close(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.pass_cash_close(timestamptz, timestamptz, uuid) to authenticated;

-- dar de baja un abono (la plata se resuelve fuera del sistema); los pasajes ya emitidos siguen valiendo
create function public.pass_void(p_pass uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare v_pass public.passes;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'REASON_REQUIRED: el motivo debe tener al menos 5 caracteres'; end if;
  select * into v_pass from public.passes where id = p_pass and company_id = public.current_company_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_pass.status <> 'active' then raise exception 'ALREADY_CANCELLED'; end if;
  update public.passes set status = 'cancelled', cancelled_at = clock_timestamp(), cancel_reason = trim(p_reason) where id = p_pass;
  insert into public.pass_movements (pass_id, kind, delta) values (p_pass, 'void', -v_pass.trips_left);
end $$;
revoke all on function public.pass_void(uuid, text) from public, anon;
grant execute on function public.pass_void(uuid, text) to authenticated;

-- ---------------------------------------------------------------- usar un abono (núcleo común)
create function public._pass_redeem(
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
revoke all on function public._pass_redeem(uuid, uuid, uuid, uuid, text, text, uuid) from public, anon, authenticated;

-- ventanilla: el vendedor usa el abono del pasajero (busca por DNI)
create function public.pass_redeem_counter(p_pass uuid, p_trip uuid, p_from uuid, p_to uuid, p_seat_label text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if public.current_user_role()::text not in ('company_admin', 'seller') then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.passes where id = p_pass and company_id = public.current_company_id()) then
    raise exception 'PASS_NOT_FOUND: el abono no existe o fue dado de baja';
  end if;
  if not public.company_feature_enabled(public.current_company_id(), 'fares') then
    raise exception 'FEATURE_BLOCKED: las tarifas, ventas y taquilla no están habilitadas para esta empresa';
  end if;
  return public._pass_redeem(p_pass, p_trip, p_from, p_to, p_seat_label, 'counter', auth.uid());
end $$;
revoke all on function public.pass_redeem_counter(uuid, uuid, uuid, uuid, text) from public, anon;
grant execute on function public.pass_redeem_counter(uuid, uuid, uuid, uuid, text) to authenticated;

-- web: el pasajero (con cuenta) usa su propio abono; mismas reglas de venta web (publicado, hasta 5 minutos antes)
create function public.pass_redeem_web(p_pass uuid, p_trip uuid, p_from uuid, p_to uuid, p_seat_label text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_dni text;
  v_trip public.trips;
begin
  select dni into v_dni from public.passenger_profiles where user_id = auth.uid();
  if v_dni is null then raise exception 'PASSENGER_PROFILE_REQUIRED'; end if;
  if not exists (select 1 from public.passes where id = p_pass and holder_dni = v_dni) then
    raise exception 'PASS_NOT_FOUND: el abono no existe o fue dado de baja';
  end if;
  select * into v_trip from public.trips where id = p_trip;
  if not found or v_trip.published_at is null or v_trip.status <> 'scheduled'
     or v_trip.scheduled_departure <= clock_timestamp() + interval '5 minutes' then
    raise exception 'TRIP_UNAVAILABLE: el viaje no está disponible para reservar';
  end if;
  perform public._require_trip_feature(p_trip, 'web', 'esta empresa no vende pasajes por la web');
  return public._pass_redeem(p_pass, p_trip, p_from, p_to, p_seat_label, 'web', null);
end $$;
revoke all on function public.pass_redeem_web(uuid, uuid, uuid, uuid, text) from public, anon;
grant execute on function public.pass_redeem_web(uuid, uuid, uuid, uuid, text) to authenticated;

-- web: mis abonos
create function public.passenger_my_passes()
returns table (pass_id uuid, company_id uuid, company_name text, place_a uuid, place_b uuid, place_a_name text, place_b_name text,
               seat_class text, trips_total int, trips_left int, purchased_at timestamptz, expires_at timestamptz,
               status text, usable boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.company_id, c.name, p.place_a, p.place_b, pa.name, pb.name, p.seat_class, p.trips_total, p.trips_left,
         p.purchased_at, p.expires_at, p.status,
         (p.status = 'active' and p.trips_left > 0 and p.expires_at > clock_timestamp())
    from public.passes p
    join public.passenger_profiles pp on pp.dni = p.holder_dni and pp.user_id = auth.uid()
    join public.companies c on c.id = p.company_id
    join public.places pa on pa.id = p.place_a
    join public.places pb on pb.id = p.place_b
   order by (p.status = 'active' and p.trips_left > 0 and p.expires_at > clock_timestamp()) desc, p.expires_at desc;
$$;
revoke all on function public.passenger_my_passes() from public, anon;
grant execute on function public.passenger_my_passes() to authenticated;

-- web: el pasajero cancela un pasaje que sacó con su abono
create function public.pass_cancel_ticket(p_ticket uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_dni text;
  v_ticket public.sale_tickets;
  v_trip public.trips;
begin
  select dni into v_dni from public.passenger_profiles where user_id = auth.uid();
  if v_dni is null then raise exception 'PASSENGER_PROFILE_REQUIRED'; end if;
  select t.* into v_ticket from public.sale_tickets t
    join public.passes p on p.id = t.pass_id and p.holder_dni = v_dni
   where t.id = p_ticket for update of t;
  if not found then raise exception 'TICKET_NOT_FOUND'; end if;
  if v_ticket.status = 'cancelled' then raise exception 'ALREADY_CANCELLED'; end if;
  if v_ticket.status = 'boarded' then raise exception 'ALREADY_BOARDED'; end if;
  select * into v_trip from public.trips where id = v_ticket.trip_id;
  if v_trip.status <> 'scheduled' then raise exception 'TRIP_CLOSED'; end if;
  update public.sale_tickets set status = 'cancelled', cancelled_at = clock_timestamp(), cancel_reason = 'Cancelado por el pasajero'
   where id = v_ticket.id;
  update public.sales set status = 'refunded', refunded_at = clock_timestamp() where id = v_ticket.sale_id;
  return jsonb_build_object('ok', true, 'returned', clock_timestamp() <= v_trip.scheduled_departure - interval '2 hours');
end $$;
revoke all on function public.pass_cancel_ticket(uuid) from public, anon;
grant execute on function public.pass_cancel_ticket(uuid) to authenticated;

-- devolver el viaje al saldo: cualquier cancelación (pasajero, ventanilla o admin) con 2 horas o más de anticipación
create function public._pass_return_on_cancel() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_departure timestamptz;
begin
  if new.pass_id is null or new.status <> 'cancelled' or old.status = 'cancelled' then return new; end if;
  select scheduled_departure into v_departure from public.trips where id = new.trip_id;
  if v_departure is not null and clock_timestamp() <= v_departure - interval '2 hours' then
    update public.passes set trips_left = least(trips_total, trips_left + 1) where id = new.pass_id;
    insert into public.pass_movements (pass_id, kind, delta, ticket_id) values (new.pass_id, 'refund', 1, new.id);
  else
    insert into public.pass_movements (pass_id, kind, delta, ticket_id) values (new.pass_id, 'forfeit', 0, new.id);
  end if;
  return new;
end $$;
revoke all on function public._pass_return_on_cancel() from public, anon, authenticated;
create trigger pass_return_on_cancel after update of status on public.sale_tickets
  for each row execute function public._pass_return_on_cancel();

notify pgrst, 'reload schema';
