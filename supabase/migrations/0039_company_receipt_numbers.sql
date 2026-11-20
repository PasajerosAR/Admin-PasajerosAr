-- Un correlativo interno de comprobante por empresa, compartido por todos los pasajes de una venta.
create table public.company_receipt_counters (
  company_id uuid primary key references public.companies (id) on delete cascade,
  last_number bigint not null default 0 check (last_number >= 0)
);
alter table public.company_receipt_counters enable row level security;
revoke all on public.company_receipt_counters from public, anon, authenticated;

alter table public.sales add column receipt_number bigint;

with numbered_sales as (
  select id, row_number() over (partition by company_id order by created_at, id) as receipt_number
    from public.sales
)
update public.sales as sale
   set receipt_number = numbered_sales.receipt_number
  from numbered_sales
 where numbered_sales.id = sale.id;

insert into public.company_receipt_counters (company_id, last_number)
select company_id, max(receipt_number)
  from public.sales
 group by company_id;

alter table public.sales alter column receipt_number set not null;
create unique index sales_company_receipt_number_idx
  on public.sales (company_id, receipt_number);

create or replace function public.assign_company_receipt_number()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.company_receipt_counters as counters (company_id, last_number)
  values (new.company_id, 1)
  on conflict (company_id) do update
    set last_number = counters.last_number + 1
  returning last_number into new.receipt_number;
  return new;
end $$;

revoke all on function public.assign_company_receipt_number() from public, anon, authenticated;
create trigger sales_assign_company_receipt_number
  before insert on public.sales
  for each row execute function public.assign_company_receipt_number();
