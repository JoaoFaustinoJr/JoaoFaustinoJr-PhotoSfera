create table photosfera.impressions (
 id uuid primary key,
 photo_sender uuid not null,
 photo_id uuid not null,
 author uuid not null references photosfera.profiles,
 body text not null check(char_length(body) between 1 and 1000),
 created_at timestamptz not null default now(),
 foreign key(photo_sender,photo_id) references photosfera.feed_photos(sender,id)
);
alter table photosfera.impressions enable row level security;
create index on photosfera.impressions(photo_sender,photo_id,created_at);
create function public.photosphera_impressions(secret text, sender uuid, photo uuid, body text default null, request_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare me uuid; result jsonb;
begin
 select id into me from photosfera.profiles where secret_hash=sha256(convert_to(secret,'UTF8'));
 if me is null then raise exception 'invalid_profile'; end if;
 if sender <> me and not exists(select from photosfera.connections where first_id=least(me,sender) and second_id=greatest(me,sender)) then raise exception 'not_connected'; end if;
 if not exists(select from photosfera.feed_photos f where f.sender=photosphera_impressions.sender and f.id=photo) then raise exception 'photo_missing'; end if;
 if body is not null then
   insert into photosfera.impressions values(coalesce(request_id,gen_random_uuid()),sender,photo,me,btrim(body),now()) on conflict(id) do nothing;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('name',p.name,'body',i.body,'created_at',i.created_at) order by i.created_at),'[]') into result
 from photosfera.impressions i join photosfera.profiles p on p.id=i.author
 where i.photo_sender=sender and i.photo_id=photo;
 return result;
end $$;
revoke all on function public.photosphera_impressions(text,uuid,uuid,text,uuid) from public,authenticated;
grant execute on function public.photosphera_impressions(text,uuid,uuid,text,uuid) to anon;

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

  if action = 'identity' then return jsonb_build_object('id',me); end if;
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
  if action = 'gallery' then
    other := (data->>'sender')::uuid;
    if other <> me and not exists (select from photosfera.connections where first_id = least(me,other) and second_id = greatest(me,other)) then
      raise exception 'not_connected';
    end if;
    select coalesce(jsonb_agg(to_jsonb(item) order by item.created_at desc, item.id desc), '[]') into result
    from (
      select f.id, f.sender, f.image, f.caption, f.metadata, f.created_at, p.name
      from photosfera.feed_photos f join photosfera.profiles p on p.id=f.sender
      where f.sender=other
      order by f.created_at desc, f.id desc
      limit 12 offset greatest(0,least(100000,coalesce((data->>'offset')::int,0)))
    ) item;
    return result;
  end if;
  if action = 'stories' then
    select coalesce(jsonb_agg(to_jsonb(latest) order by latest.created_at desc), '[]') into result
    from (
      select distinct on (candidate.sender) candidate.*, p.name
      from (
        select f.id, f.sender, f.image, f.caption, f.created_at, f.metadata
        from photosfera.photos f where f.recipient = me
        union all
        select f.id, f.sender, f.image, f.caption, f.created_at, f.metadata
        from photosfera.feed_photos f
      ) candidate
      join photosfera.profiles p on p.id = candidate.sender
      join photosfera.connections c
        on c.first_id = least(me, candidate.sender) and c.second_id = greatest(me, candidate.sender)
      order by candidate.sender, candidate.created_at desc, candidate.id desc
    ) latest;
    return result;
  end if;
  if action = 'feed' then
    select coalesce(jsonb_agg(to_jsonb(recent) order by recent.created_at desc), '[]') into result
    from (select f.id, p.name, f.image, f.caption, f.created_at, f.metadata
      from photosfera.photos f join photosfera.profiles p on p.id = f.sender
      where f.recipient = me
      union all
      select f.id, p.name, f.image, f.caption, f.created_at, f.metadata
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
    insert into photosfera.photos (id,sender,recipient,image,caption,created_at) values ((data->>'id')::uuid, me, other, data->>'image', coalesce(data->>'caption', ''), now())
      on conflict (id) do nothing;
    return '{}'::jsonb;
  end if;
  if action = 'publish' then
    if data->>'image' is null or length(data->>'image') > 600000
       or data->>'image' !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$'
       or length(coalesce(data->>'caption', '')) > 400 then
      raise exception 'invalid_photo';
    end if;
    if jsonb_typeof(coalesce(data->'metadata','{}')) <> 'object' or octet_length(coalesce(data->'metadata','{}')::text) > 12000 then raise exception 'invalid_metadata'; end if;
    insert into photosfera.feed_photos (sender, id, image, caption, metadata)
      values (me, (data->>'id')::uuid, data->>'image', coalesce(data->>'caption', ''), coalesce(data->'metadata','{}'))
      on conflict (sender, id) do update set metadata = case when excluded.metadata <> '{}'::jsonb then excluded.metadata else photosfera.feed_photos.metadata end;
    return '{}'::jsonb;
  end if;
  raise exception 'invalid_action';
end
$$;
