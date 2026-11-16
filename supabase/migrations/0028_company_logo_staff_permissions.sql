drop policy company_logos_company_admin_insert on storage.objects;
create policy company_logos_company_admin_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'company-logos'
    and (
      public.has_platform_permission('companies', true)
      or (
        public.is_company_admin()
        and split_part(name, '/', 1) = public.current_company_id()::text
      )
    )
  );

drop policy company_logos_company_admin_update on storage.objects;
create policy company_logos_company_admin_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'company-logos'
    and (
      public.has_platform_permission('companies', true)
      or (
        public.is_company_admin()
        and split_part(name, '/', 1) = public.current_company_id()::text
      )
    )
  )
  with check (
    bucket_id = 'company-logos'
    and (
      public.has_platform_permission('companies', true)
      or (
        public.is_company_admin()
        and split_part(name, '/', 1) = public.current_company_id()::text
      )
    )
  );

drop policy company_logos_company_admin_delete on storage.objects;
create policy company_logos_company_admin_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'company-logos'
    and (
      public.has_platform_permission('companies', true)
      or (
        public.is_company_admin()
        and split_part(name, '/', 1) = public.current_company_id()::text
      )
    )
  );

create or replace function public.save_company_logo(p_company uuid, p_logo_path text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_file_name text;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not public.has_platform_permission('companies', true)
     and not (public.is_company_admin() and public.current_company_id() = p_company) then
    raise exception 'FORBIDDEN';
  end if;
  if p_company is null then raise exception 'COMPANY_INVALID'; end if;

  if p_logo_path is not null then
    v_file_name := split_part(p_logo_path, '/', 2);
    if split_part(p_logo_path, '/', 1) <> p_company::text
       or array_length(string_to_array(p_logo_path, '/'), 1) <> 2
       or v_file_name !~* '^[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$' then
      raise exception 'LOGO_PATH_INVALID';
    end if;
  end if;

  update public.companies
     set logo_path = p_logo_path
   where id = p_company;
  if not found then raise exception 'COMPANY_NOT_FOUND'; end if;
end
$$;
