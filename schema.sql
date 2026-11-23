-- Ved Optics Scratch & Win: run this whole script in Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.ved_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Ved Optics Admin'
);

create table if not exists public.scratch_cards (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  branch text not null check (branch in ('Chandkheda','Vaishnodevi Circle')),
  status text not null default 'unused' check (status in ('unused','scratched','redeemed')),
  prize_key text,
  prize_label text,
  prize_description text,
  emoji text,
  customer_name text,
  customer_mobile text,
  scratched_at timestamptz,
  redeemed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.scratch_cards enable row level security;
alter table public.ved_admins enable row level security;
-- No direct table access is granted to anon/authenticated. Use the controlled RPC functions below.

create or replace function public.scratch_card(p_code text,p_name text,p_mobile text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.scratch_cards%rowtype; n int; k text; lbl text; descr text; em text;
begin
  if length(trim(coalesce(p_name,'')))<1 or p_mobile !~ '^[0-9]{10}$' then
    return jsonb_build_object('ok',false,'message','Please enter a valid name and 10-digit mobile number.');
  end if;
  select * into c from public.scratch_cards where code=upper(trim(p_code)) for update;
  if not found then return jsonb_build_object('ok',false,'message','Invalid card code.'); end if;
  if c.status <> 'unused' then return jsonb_build_object('ok',false,'message','This card has already been used.'); end if;
  -- Prize selection happens on the server and is stored once against this unique card.
  n := floor(random()*100)::int;
  if n < 30 then k:='discount_5'; lbl:='5% DISCOUNT'; descr:='Discount on an eligible purchase'; em:='🎉';
  elsif n < 55 then k:='discount_10'; lbl:='10% DISCOUNT'; descr:='Discount on an eligible purchase'; em:='🌟';
  elsif n < 65 then k:='discount_20'; lbl:='20% DISCOUNT'; descr:='Discount on an eligible purchase'; em:='🏆';
  elsif n < 85 then k:='discount_100'; lbl:='₹100 DISCOUNT'; descr:='Discount on an eligible purchase'; em:='🎁';
  elsif n < 93 then k:='free_sunglasses'; lbl:='FREE SUNGLASSES'; descr:='Gift on an eligible purchase'; em:='🕶️';
  else k:='lens_upgrade'; lbl:='FREE LENS UPGRADE'; descr:='On eligible lenses'; em:='✨'; end if;
  update public.scratch_cards set status='scratched',prize_key=k,prize_label=lbl,prize_description=descr,emoji=em,
    customer_name=trim(p_name),customer_mobile=p_mobile,scratched_at=now()
  where id=c.id;
  return jsonb_build_object('ok',true,'prize_key',k,'prize_label',lbl,'prize_description',descr,'emoji',em,'branch',c.branch);
end $$;

create or replace function public.admin_create_cards(p_count int,p_branch text)
returns table(code text) language plpgsql security definer set search_path=public as $$
declare i int; v text;
begin
  if not exists(select 1 from public.ved_admins where user_id=auth.uid()) then raise exception 'Admin access required'; end if;
  if p_count<1 or p_count>500 then raise exception 'Choose between 1 and 500 cards'; end if;
  if p_branch not in ('Chandkheda','Vaishnodevi Circle') then raise exception 'Invalid branch'; end if;
  for i in 1..p_count loop
    v := upper(encode(gen_random_bytes(6),'hex'));
    insert into public.scratch_cards(code,branch) values(v,p_branch);
    code := v; return next;
  end loop;
end $$;

create or replace function public.admin_dashboard()
returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
  if not exists(select 1 from public.ved_admins where user_id=auth.uid()) then raise exception 'Admin access required'; end if;
  select jsonb_build_object(
    'stats',jsonb_build_object(
      'total',count(*),
      'scratched',count(*) filter(where status in ('scratched','redeemed')),
      'redeemed',count(*) filter(where status='redeemed'),
      'unused',count(*) filter(where status='unused')
    ),
    'cards',coalesce(jsonb_agg(jsonb_build_object(
      'id',id,'code',code,'branch',branch,'status',status,'prize_label',prize_label,
      'customer_name',customer_name,'customer_mobile',customer_mobile,'created_at',created_at
    ) order by created_at desc),'[]'::jsonb)
  ) into result from public.scratch_cards;
  return result;
end $$;

create or replace function public.admin_redeem_card(p_card_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare changed int;
begin
  if not exists(select 1 from public.ved_admins where user_id=auth.uid()) then raise exception 'Admin access required'; end if;
  update public.scratch_cards set status='redeemed',redeemed_at=now()
  where id=p_card_id and status='scratched';
  get diagnostics changed = row_count;
  if changed=0 then return jsonb_build_object('ok',false,'message','Card is not in scratched status or was already redeemed.'); end if;
  return jsonb_build_object('ok',true,'message','Reward marked as redeemed.');
end $$;

revoke all on function public.scratch_card(text,text,text) from public;
revoke all on function public.admin_create_cards(int,text) from public;
revoke all on function public.admin_dashboard() from public;
revoke all on function public.admin_redeem_card(uuid) from public;
grant execute on function public.scratch_card(text,text,text) to anon,authenticated;
grant execute on function public.admin_create_cards(int,text) to authenticated;
grant execute on function public.admin_dashboard() to authenticated;
grant execute on function public.admin_redeem_card(uuid) to authenticated;
