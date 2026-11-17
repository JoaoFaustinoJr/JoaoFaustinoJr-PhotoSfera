create schema if not exists photosfera;
create table photosfera.profiles (
  id uuid primary key default gen_random_uuid(),
  secret_hash bytea not null unique,
  name text not null
);
create table photosfera.invites (
  token uuid primary key,
  sender uuid not null unique references photosfera.profiles,
  expires timestamptz not null default now() + interval '48 hours'
);
create table photosfera.connections (
  first_id uuid references photosfera.profiles,
  second_id uuid references photosfera.profiles,
  primary key (first_id, second_id),
  check (first_id < second_id)
);
create table photosfera.photos (
  id uuid primary key,
  sender uuid not null references photosfera.profiles,
  recipient uuid not null references photosfera.profiles,
  image text not null,
  caption text not null,
  created_at timestamptz not null default now()
);
alter table photosfera.profiles enable row level security;
alter table photosfera.invites enable row level security;
alter table photosfera.connections enable row level security;
alter table photosfera.photos enable row level security;
create index on photosfera.photos (recipient, created_at desc);

create function public.photosfera_connections(action text, secret text, data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid;
  other uuid;
  token uuid;
  display_name text := btrim(data->>'name');
  result jsonb;
begin
  if secret is null or secret !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_profile';
  end if;
  select id into me from photosfera.profiles where secret_hash = sha256(convert_to(secret, 'UTF8'));
  if action = 'profile' then
    if display_name is null or char_length(display_name) not between 1 and 60 then
      raise exception 'invalid_name';
    end if;
    insert into photosfera.profiles (secret_hash, name)
      values (sha256(convert_to(secret, 'UTF8')), display_name)
      on conflict (secret_hash) do update set name = excluded.name;
    return '{}'::jsonb;
  end if;
  if me is null then raise exception 'invalid_profile'; end if;

  if action = 'invite' then
    token := gen_random_uuid();
    insert into photosfera.invites (sender, token) values (me, token)
      on conflict (sender) do update set token = excluded.token, expires = excluded.expires;
    return jsonb_build_object('token', token);
  end if;
  if action in ('preview', 'accept') then
    select i.sender, p.name into other, display_name
      from photosfera.invites i join photosfera.profiles p on p.id = i.sender
      where i.token = (data->>'token')::uuid and i.expires > now()
      for update of i;
    if other is null then raise exception 'invite_expired'; end if;
    if other = me then raise exception 'own_invite'; end if;
    if action = 'accept' then
      insert into photosfera.connections values (least(me, other), greatest(me, other)) on conflict do nothing;
      delete from photosfera.invites i where i.token = (data->>'token')::uuid;
    end if;
    return jsonb_build_object('name', display_name);
  end if;
  if action = 'contacts' then
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.name), '[]')
      into result from photosfera.connections c join photosfera.profiles p
      on (c.first_id = me and c.second_id = p.id) or (c.second_id = me and c.first_id = p.id);
    return result;
  end if;
  if action = 'feed' then
    select coalesce(jsonb_agg(to_jsonb(recent) order by recent.created_at desc), '[]') into result
    from (select f.id, p.name, f.image, f.caption, f.created_at
      from photosfera.photos f join photosfera.profiles p on p.id = f.sender
      where f.recipient = me order by f.created_at desc limit 20) recent;
    return result;
  end if;
  if action = 'share' then
    other := (data->>'recipient')::uuid;
    if not exists (select from photosfera.connections
       where first_id = least(me, other) and second_id = greatest(me, other)) then
      raise exception 'not_connected';
    end if;
    if data->>'image' is null or length(data->>'image') > 600000
       or data->>'image' !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$'
       or length(coalesce(data->>'caption', '')) > 400 then
      raise exception 'invalid_photo';
    end if;
    insert into photosfera.photos values ((data->>'id')::uuid, me, other, data->>'image', coalesce(data->>'caption', ''), now())
      on conflict (id) do nothing;
    return '{}'::jsonb;
  end if;
  raise exception 'invalid_action';
end
$$;
revoke all on function public.photosfera_connections(text,text,jsonb) from public, anon, authenticated;
grant execute on function public.photosfera_connections(text,text,jsonb) to anon;
