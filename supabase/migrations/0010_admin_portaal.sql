-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0010: sessie-momenten en account-goedkeuring (admin portaal)
-- ----------------------------------------------------------------------------
-- Voor het admin portaal:
--   - Een sessie (bv. "Yoga") kan MEERDERE momenten hebben (dag + tijd),
--     elk terugkerend op een weekdag. We splitsen 'clubsessies' daarom in een
--     sessie (naam + activiteit) en losse momenten.
--   - Nieuwe accounts krijgen een goedkeuringsstatus zodat een admin ze kan
--     goedkeuren, afwijzen of bewerken.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. SESSIE-MOMENTEN
-- De bestaande clubsessies-tabel houdt de sessie zelf bij (naam + activiteit).
-- Een nieuw tabelletje houdt de terugkerende momenten bij.
-- ----------------------------------------------------------------------------
create table sessie_momenten (
    id            uuid primary key default gen_random_uuid(),
    clubsessie_id uuid not null references clubsessies(id) on delete cascade,
    weekdag       integer not null check (weekdag between 0 and 6), -- 0=zo .. 6=za
    start_tijd    time not null,
    eind_tijd     time,
    actief        boolean not null default true
);

comment on table sessie_momenten is
    'Terugkerende momenten van een sessie (bv. Yoga op dinsdag 18u en zondag 10u). Eén sessie kan meerdere momenten hebben.';

create index idx_sessie_momenten_sessie on sessie_momenten(clubsessie_id);
create index idx_sessie_momenten_dag on sessie_momenten(weekdag) where actief;


-- ----------------------------------------------------------------------------
-- 2. fn_momenten_van_dag (vervangt/uitbreiding van fn_sessies_van_dag)
-- Geeft alle sessie-momenten van een bepaalde weekdag terug, met sessienaam
-- en activiteit, zodat de check-in enkel de sessies van vandaag toont.
-- ----------------------------------------------------------------------------
create or replace function fn_momenten_van_dag(p_datum date)
returns table (
    moment_id     uuid,
    clubsessie_id uuid,
    naam          text,
    activiteit    text,
    start_tijd    time,
    eind_tijd     time
)
language sql
stable
as $$
    select m.id, c.id, c.naam, c.activiteit, m.start_tijd, m.eind_tijd
    from sessie_momenten m
    join clubsessies c on c.id = m.clubsessie_id
    where m.actief and c.actief
      and m.weekdag = extract(dow from p_datum)::int
    order by m.start_tijd, c.naam;
$$;

comment on function fn_momenten_van_dag is
    'Geeft de sessie-momenten van een dag (op weekdag), met sessienaam en activiteit. Voor de check-in.';


-- ----------------------------------------------------------------------------
-- 3. ACCOUNT-GOEDKEURING
-- Nieuwe leden (vooral via zelfregistratie, maar ook nieuw aangemaakt aan de
-- kassa) krijgen een status. Een admin keurt ze goed, wijst ze af of bewerkt.
-- ----------------------------------------------------------------------------
do $$
begin
    if not exists (select 1 from pg_type where typname = 'goedkeuring_status') then
        create type goedkeuring_status as enum ('nieuw', 'goedgekeurd', 'afgewezen');
    end if;
end$$;

alter table leden
    add column if not exists goedkeuring goedkeuring_status not null default 'goedgekeurd',
    add column if not exists goedgekeurd_door uuid references medewerkers(id),
    add column if not exists goedgekeurd_op timestamptz;

comment on column leden.goedkeuring is
    'Goedkeuringsstatus van het profiel. Nieuwe accounts staan op ''nieuw'' tot een admin ze goedkeurt of afwijst.';

-- Nieuw aangemaakte profielen (zelfregistratie / kassa) zetten we standaard op
-- 'nieuw' in de app-laag; bestaande leden blijven 'goedgekeurd'.


-- ----------------------------------------------------------------------------
-- 4. fn_keur_account_goed / fn_wijs_account_af
-- ----------------------------------------------------------------------------
create or replace function fn_keur_account_goed(
    p_lid_id         uuid,
    p_medewerker_id  uuid
)
returns void
language plpgsql
as $$
begin
    update leden
       set goedkeuring = 'goedgekeurd',
           goedgekeurd_door = p_medewerker_id,
           goedgekeurd_op = now()
     where id = p_lid_id;
    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'account_goedgekeurd', 'Account goedgekeurd door admin.', p_lid_id);
end;
$$;

create or replace function fn_wijs_account_af(
    p_lid_id         uuid,
    p_medewerker_id  uuid
)
returns void
language plpgsql
as $$
begin
    update leden
       set goedkeuring = 'afgewezen', actief = false
     where id = p_lid_id;
    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'account_afgewezen', 'Account afgewezen door admin.', p_lid_id);
end;
$$;

comment on function fn_keur_account_goed is 'Keurt een nieuw account goed (admin).';
comment on function fn_wijs_account_af is 'Wijst een nieuw account af en zet het op inactief (admin).';
