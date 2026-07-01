-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0017: tegoed ongedaan maken (iedereen) + beurten aftrekken (admin)
-- ----------------------------------------------------------------------------
-- fn_laad_beurtenkaart en fn_laad_abonnement maken ALTIJD een nieuwe rij aan
-- (nooit stapelen op een bestaande kaart/abonnement) en geven het nieuwe id
-- terug. "Ongedaan maken" is daardoor simpel: verwijder precies die rij.
--
--   - fn_annuleer_beurtenkaart: enkel toegestaan als er nog geen beurt van
--     afgetrokken is (beurten_resterend = beurten_totaal) — anders zou
--     ongedaan maken een intussen al gebruikte beurt laten verdwijnen.
--     Beschikbaar voor elke medewerker (geen admin-check), net als het
--     toevoegen zelf.
--   - fn_annuleer_abonnement: abonnementen worden nooit "verbruikt" (enkel
--     op geldigheidsdatum gecheckt), dus geen vergelijkbare guard nodig.
--   - fn_trek_beurten_af: HANDMATIG beurten aftrekken, enkel voor admins
--     (UI-gated, zelfde patroon als andere admin-acties in deze app —
--     geen harde rol-check in de functie zelf). Trekt af van de oudste
--     kaart(en) eerst (zelfde volgorde als fn_beschikbaar_tegoed), en
--     weigert als er onvoldoende tegoed is (geen gedeeltelijke aftrek).
-- ============================================================================
create or replace function fn_annuleer_beurtenkaart(
    p_beurtenkaart_id  uuid,
    p_medewerker_id    uuid
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
    v_kaart beurtenkaarten%rowtype;
begin
    select * into v_kaart from beurtenkaarten where id = p_beurtenkaart_id;
    if not found then
        return 'Kaart niet gevonden (misschien al ongedaan gemaakt).';
    end if;
    if v_kaart.beurten_resterend <> v_kaart.beurten_totaal then
        return 'Er is al een beurt van deze kaart gebruikt; kan niet meer ongedaan gemaakt worden.';
    end if;

    delete from beurtenkaarten where id = p_beurtenkaart_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'beurtenkaart_ongedaan',
            'Beurtenkaart ongedaan gemaakt: ' || v_kaart.beurten_totaal || ' beurten ' || v_kaart.activiteit || '.',
            v_kaart.lid_id);
    return 'ok';
end;
$$;

comment on function fn_annuleer_beurtenkaart is
    'Maakt het net toevoegen van een beurtenkaart ongedaan (enkel als er nog geen beurt van afgetrokken is). Voor elke medewerker.';

create or replace function fn_annuleer_abonnement(
    p_abonnement_id  uuid,
    p_medewerker_id  uuid
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
    v_abo abonnementen%rowtype;
begin
    select * into v_abo from abonnementen where id = p_abonnement_id;
    if not found then
        return 'Abonnement niet gevonden (misschien al ongedaan gemaakt).';
    end if;

    delete from abonnementen where id = p_abonnement_id;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'abonnement_ongedaan',
            'Abonnement ongedaan gemaakt: ' || v_abo.activiteit || ' (tot ' || v_abo.eind_datum || ').',
            v_abo.lid_id);
    return 'ok';
end;
$$;

comment on function fn_annuleer_abonnement is
    'Maakt het net toevoegen van een abonnement ongedaan. Voor elke medewerker.';

create or replace function fn_trek_beurten_af(
    p_lid_id        uuid,
    p_activiteit    text,
    p_aantal        integer,
    p_medewerker_id uuid
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
    v_beschikbaar  integer;
    v_resterend    integer;
    r              record;
begin
    if p_aantal is null or p_aantal <= 0 then
        return 'Geef een aantal groter dan 0.';
    end if;

    select coalesce(sum(beurten_resterend), 0) into v_beschikbaar
      from beurtenkaarten
     where lid_id = p_lid_id and actief and activiteit = p_activiteit;

    if v_beschikbaar < p_aantal then
        return 'Onvoldoende beurten om af te trekken (nog ' || v_beschikbaar || ' beschikbaar).';
    end if;

    v_resterend := p_aantal;
    for r in
        select id, beurten_resterend from beurtenkaarten
         where lid_id = p_lid_id and actief and activiteit = p_activiteit and beurten_resterend > 0
         order by aangemaakt_op asc
    loop
        exit when v_resterend <= 0;
        if r.beurten_resterend >= v_resterend then
            update beurtenkaarten set beurten_resterend = beurten_resterend - v_resterend where id = r.id;
            v_resterend := 0;
        else
            update beurtenkaarten set beurten_resterend = 0 where id = r.id;
            v_resterend := v_resterend - r.beurten_resterend;
        end if;
    end loop;

    insert into handelingen_log (medewerker_id, handeling, omschrijving, lid_id)
    values (p_medewerker_id, 'beurten_afgetrokken',
            p_aantal || ' beurten ' || p_activiteit || ' handmatig afgetrokken.', p_lid_id);
    return 'ok';
end;
$$;

comment on function fn_trek_beurten_af is
    'Trekt handmatig beurten af van de oudste kaart(en) eerst; weigert bij onvoldoende tegoed. Bedoeld voor admins (UI-gated).';

grant execute on function fn_annuleer_beurtenkaart(uuid, uuid) to anon;
grant execute on function fn_annuleer_abonnement(uuid, uuid) to anon;
grant execute on function fn_trek_beurten_af(uuid, text, integer, uuid) to anon;
