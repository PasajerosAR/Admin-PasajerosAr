-- Compra online de abonos con Mercado Pago (cada empresa cobra en su cuenta, igual que los pasajes).

-- borrar un producto no debe fallar porque ya se vendieron abonos de ese producto
alter table public.passes drop constraint if exists passes_product_id_fkey;
alter table public.passes add constraint passes_product_id_fkey foreign key (product_id) references public.pass_products (id) on delete set null;

create table public.pass_checkout_orders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  mp_connection_id uuid not null references public.mp_company_connections (company_id),
  passenger_user_id uuid not null references auth.users (id) on delete cascade,
  product_id uuid references public.pass_products (id) on delete set null,
  -- copia del producto al momento de comprar (si la empresa lo cambia después, vale lo que se pagó)
  place_a uuid not null references public.places (id),
  place_b uuid not null references public.places (id),
  seat_class text,
  trips int not null check (trips >= 1),
  valid_days int not null check (valid_days >= 1),
  price numeric(10, 2) not null check (price > 0),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'cancelled', 'expired', 'refund_required')),
  refund_status text check (refund_status in ('pending', 'refunded', 'failed')),
  preference_id text,
  checkout_url text,
  mp_payment_id text unique,
  pass_id uuid references public.passes (id) on delete set null,
  expires_at timestamptz not null default (now() + interval '30 minutes'),
  created_at timestamptz not null default now()
);
create index pass_checkout_user_idx on public.pass_checkout_orders (passenger_user_id, created_at desc);
alter table public.pass_checkout_orders enable row level security;
revoke all on public.pass_checkout_orders from public, anon, authenticated;
grant all on public.pass_checkout_orders to service_role;

-- catálogo público: abonos activos de empresas que venden por la web y tienen Mercado Pago conectado
create function public.passenger_pass_catalog()
returns table (product_id uuid, company_id uuid, company_name text, place_a_name text, place_b_name text,
               seat_class text, trips int, price numeric, valid_days int)
language sql stable security definer set search_path = public as $$
  select p.id, p.company_id, c.name, pa.name, pb.name, p.seat_class, p.trips, p.price, p.valid_days
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

-- la llama la función de borde (service_role): valida y crea el pedido de pago
create function public.begin_pass_checkout(p_user uuid, p_product uuid) returns jsonb
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
  insert into public.pass_checkout_orders (company_id, mp_connection_id, passenger_user_id, product_id, place_a, place_b, seat_class, trips, valid_days, price)
  values (v_prod.company_id, v_prod.company_id, p_user, v_prod.id, v_prod.place_a, v_prod.place_b, v_prod.seat_class, v_prod.trips, v_prod.valid_days, v_prod.price)
  returning id, expires_at into v_order, v_expires;
  select 'Abono ' || v_prod.trips || ' viajes · ' || pa.name || ' - ' || pb.name || coalesce(' · ' || v_prod.seat_class, '')
    into v_title from public.places pa, public.places pb where pa.id = v_prod.place_a and pb.id = v_prod.place_b;
  return jsonb_build_object('order_id', v_order, 'company_id', v_prod.company_id, 'price', v_prod.price, 'title', v_title, 'expires_at', v_expires);
end $$;
revoke all on function public.begin_pass_checkout(uuid, uuid) from public, anon, authenticated;
grant execute on function public.begin_pass_checkout(uuid, uuid) to service_role;

create function public.fail_pass_checkout(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' then raise exception 'FORBIDDEN'; end if;
  update public.pass_checkout_orders set status = 'cancelled' where id = p_order and status = 'pending';
end $$;
revoke all on function public.fail_pass_checkout(uuid) from public, anon, authenticated;
grant execute on function public.fail_pass_checkout(uuid) to service_role;

-- la llama el aviso de pago aprobado: crea el abono a nombre del titular de la cuenta (por su DNI)
create function public.finalize_pass_checkout(p_order uuid, p_payment_id text, p_amount numeric, p_currency text) returns jsonb
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
                             trips_total, trips_left, price, payment_method, sold_by, expires_at)
  values (v_order.company_id, v_order.product_id, v_order.place_a, v_order.place_b, v_order.seat_class, v_profile.dni,
          trim(v_profile.first_name || ' ' || v_profile.last_name), v_profile.email,
          v_order.trips, v_order.trips, v_order.price, 'mp', null, v_expires)
  returning id into v_pass;
  insert into public.pass_movements (pass_id, kind, delta) values (v_pass, 'sale', v_order.trips);
  update public.pass_checkout_orders set status = 'approved', mp_payment_id = p_payment_id, pass_id = v_pass where id = v_order.id;
  return jsonb_build_object('status', 'approved', 'pass_id', v_pass);
end $$;
revoke all on function public.finalize_pass_checkout(uuid, text, numeric, text) from public, anon, authenticated;
grant execute on function public.finalize_pass_checkout(uuid, text, numeric, text) to service_role;

create function public.pass_checkout_status(p_order uuid)
returns table (status text, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  update public.pass_checkout_orders as o set status = 'expired'
   where o.id = p_order and o.passenger_user_id = auth.uid() and o.status = 'pending' and o.expires_at <= clock_timestamp();
  return query select o.status, o.expires_at from public.pass_checkout_orders o where o.id = p_order and o.passenger_user_id = auth.uid();
end $$;
revoke all on function public.pass_checkout_status(uuid) from public, anon;
grant execute on function public.pass_checkout_status(uuid) to authenticated;

notify pgrst, 'reload schema';
