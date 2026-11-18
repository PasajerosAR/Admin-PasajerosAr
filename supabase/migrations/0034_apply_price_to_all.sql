-- "Aplicar a todos": carga un mismo precio para todos los tramos de un recorrido entre localidades distintas
-- (ascenso en una localidad, descenso en otra), para la clase de asiento indicada (null = todas las clases).
-- Reutiliza save_ticket_price: respeta el bloqueo de tarifas, actualiza las tarifas existentes y no duplica.

create function public.apply_price_to_all(p_route uuid, p_price numeric, p_seat_class text default null)
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_pair record;
  v_n int := 0;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_route is null or p_price is null or p_price < 0 then raise exception 'PRICE_INVALID: revisá el precio'; end if;
  for v_pair in
    select f.position as from_pos, t.position as to_pos
      from public.route_stops f
      join public.route_stops t on t.route_id = f.route_id and t.position > f.position
     where f.route_id = p_route
       and coalesce(f.place_id::text, f.id::text) <> coalesce(t.place_id::text, t.id::text)
     order by f.position, t.position
  loop
    perform public.save_ticket_price(p_route, v_pair.from_pos, v_pair.to_pos, p_price, p_seat_class);
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'ROUTE_INVALID: el recorrido no tiene tramos entre localidades distintas'; end if;
  return v_n;
end $$;
revoke all on function public.apply_price_to_all(uuid, numeric, text) from public, anon, authenticated;
grant execute on function public.apply_price_to_all(uuid, numeric, text) to authenticated;
