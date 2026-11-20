-- Ventanilla: la misma venta de la taquilla, con debito/credito, correo opcional del pasajero,
-- busqueda de pasajero por DNI y cierre de caja por vendedor.

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
  v_role text := public.current_user_role()::text;
  v_email text;
  v_phone text;
begin
  if p_payment_method not in ('cash', 'transfer', 'debit', 'credit')
     or (v_role = 'driver' and p_payment_method in ('debit', 'credit')) then
    raise exception 'PAYMENT_INVALID: forma de pago no habilitada';
  end if;
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) < 1 or jsonb_array_length(p_seats) > 20 then
    raise exception 'SALE_INVALID: elegí al menos un asiento';
  end if;
  select * into v_ctx from public._taquilla_ctx(p_trip, true);

  insert into public.sales (company_id, seller_id, trip_id, payment_method, total, notes)
  values (v_ctx.o_company, auth.uid(), p_trip, p_payment_method, 0, case when v_role = 'driver' then 'Venta en taquilla' else 'Venta en ventanilla' end)
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
      passenger_name, passenger_dni, passenger_email, passenger_phone, price, qr_code, is_complimentary, status
    ) values (
      v_ctx.o_company, v_sale, p_trip, v_s.o_label, v_s.o_cell, v_s.o_from, v_s.o_to,
      v_name, v_dni, v_email, v_phone, v_price, v_qr, false, 'valid'
    ) returning id into v_id;
    v_total := v_total + v_price;
    v_tickets := v_tickets || jsonb_build_array(jsonb_build_object(
      'id', v_id, 'qr_code', v_qr, 'seat_label', v_s.o_label, 'price', v_price,
      'passenger_name', v_name, 'passenger_dni', v_dni, 'email', case when v_email = 'taquilla@pasajeros.ar' then null else v_email end,
      'from_stop_id', v_s.o_from, 'to_stop_id', v_s.o_to));
  end loop;

  update public.sales set total = v_total where id = v_sale;
  delete from public.seat_holds where trip_id = p_trip and (held_by = auth.uid() or expires_at <= clock_timestamp());
  return jsonb_build_object('sale_id', v_sale, 'tickets', v_tickets, 'total', v_total);
end $$;

-- ya tiene los permisos de la 0031 (create or replace los conserva)

-- Busca un pasajero por DNI: primero su cuenta de la web, si no el ultimo pasaje que se le vendio en la empresa.
create or replace function public.ventanilla_find_passenger(p_dni text)
returns table (full_name text, email text, source text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_dni text := regexp_replace(coalesce(p_dni, ''), '[^0-9]', '', 'g');
  v_role text := public.current_user_role()::text;
begin
  if v_role is null or v_role not in ('driver', 'company_admin', 'seller') then raise exception 'FORBIDDEN'; end if;
  if length(v_dni) < 6 then return; end if;
  return query
    select trim(pp.first_name || ' ' || pp.last_name), pp.email::text, 'web'::text
      from public.passenger_profiles pp where pp.dni = v_dni limit 1;
  if found then return; end if;
  return query
    select st.passenger_name, case when st.passenger_email = 'taquilla@pasajeros.ar' then null else st.passenger_email end, 'historial'::text
      from public.sale_tickets st
     where st.company_id = public.current_company_id()
       and regexp_replace(st.passenger_dni, '[^0-9]', '', 'g') = v_dni
     order by st.created_at desc limit 1;
end $$;
revoke all on function public.ventanilla_find_passenger(text) from public, anon;
grant execute on function public.ventanilla_find_passenger(text) to authenticated;

-- Cierre de caja: lo cobrado por vendedor y forma de pago en un rango. El vendedor ve lo suyo; el admin de empresa, todo o un vendedor.
create or replace function public.cash_close(p_from timestamptz, p_to timestamptz, p_seller uuid default null)
returns table (seller_id uuid, seller_name text, payment_method public.payment_method,
               sales bigint, tickets bigint, collected numeric, refunded numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  v_role text := public.current_user_role()::text;
  v_seller uuid := p_seller;
begin
  if v_role not in ('company_admin', 'seller') then raise exception 'FORBIDDEN'; end if;
  if v_role = 'seller' then v_seller := auth.uid(); end if;
  return query
    select s.seller_id, p.full_name, s.payment_method,
           count(distinct s.id), count(t.id) filter (where t.status <> 'cancelled'),
           coalesce(sum(t.price) filter (where t.status <> 'cancelled'), 0)::numeric,
           coalesce(sum(t.price) filter (where t.status = 'cancelled'), 0)::numeric
      from public.sales s
      join public.profiles p on p.id = s.seller_id
      left join public.sale_tickets t on t.sale_id = s.id
     where s.company_id = public.current_company_id()
       and s.created_at >= p_from and s.created_at < p_to
       and (v_seller is null or s.seller_id = v_seller)
     group by s.seller_id, p.full_name, s.payment_method
     order by p.full_name, s.payment_method;
end $$;
revoke all on function public.cash_close(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.cash_close(timestamptz, timestamptz, uuid) to authenticated;
