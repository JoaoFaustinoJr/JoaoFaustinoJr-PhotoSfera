create table photosfera.feed_photos (
  sender uuid references photosfera.profiles,
  id uuid not null,
  image text not null,
  caption text not null,
  created_at timestamptz not null default now(),
  primary key (sender, id)
);
alter table photosfera.feed_photos enable row level security;
create index on photosfera.feed_photos (sender, created_at desc);
create or replace function public.photosfera_connections(action text, secret text, data jsonb default '{}')
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
      where f.recipient = me
      union all
      select f.id, p.name, f.image, f.caption, f.created_at
      from photosfera.feed_photos f join photosfera.profiles p on p.id = f.sender
      join photosfera.connections c on c.first_id = least(me, f.sender) and c.second_id = greatest(me, f.sender)
      order by created_at desc limit 20) recent;
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
  if action = 'publish' then
    if data->>'image' is null or length(data->>'image') > 600000
       or data->>'image' !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$'
       or length(coalesce(data->>'caption', '')) > 400 then
      raise exception 'invalid_photo';
    end if;
    insert into photosfera.feed_photos (sender, id, image, caption)
      values (me, (data->>'id')::uuid, data->>'image', coalesce(data->>'caption', ''))
      on conflict (sender, id) do nothing;
    return '{}'::jsonb;
  end if;
  raise exception 'invalid_action';
end
$$;
