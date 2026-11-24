-- catálogo de abonos de la web: agrega el logo de la empresa (mismo que usa el directorio de empresas)
drop function if exists public.passenger_pass_catalog();
create function public.passenger_pass_catalog()
returns table (product_id uuid, company_id uuid, company_name text, logo_path text, place_a_name text, place_b_name text,
               seat_class text, trips int, price numeric, valid_days int)
language sql stable security definer set search_path = public as $$
  select p.id, p.company_id, c.name, c.logo_path, pa.name, pb.name, p.seat_class, p.trips, p.price, p.valid_days
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
notify pgrst, 'reload schema';
