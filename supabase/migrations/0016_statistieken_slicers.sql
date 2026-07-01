-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0016: statistieken — tijdlijn-chart + slicers (periode/activiteit/sessie)
-- ----------------------------------------------------------------------------
-- Uitbreiding op migratie 0015 na gebruikersfeedback:
--   - Nieuwe tijdlijn: check-ins per dag/week per activiteit (voor een chart).
--   - De bestaande reeksen (leeftijd/postcode/herkomst/deelnames) worden nu
--     ook filterbaar op periode, activiteit en sessie (clubsessie).
-- Alle reeksen zijn nog steeds anonieme, gegroepeerde aantallen (GDPR) —
-- leeftijd/postcode/herkomst tellen wel enkel DISTINCTe leden binnen de
-- gekozen filters (zodat iemand die drie keer inchecte niet driemaal
-- meetelt in bv. de postcode-verdeling); "deelnames per activiteit" telt
-- wel elke check-in afzonderlijk (dat is precies "hoe vaak" iets gebeurde).
-- Vervangt fn_statistieken() door een geparametriseerde versie -> eerst de
-- oude (0-parameter) functie droppen, anders blijft ze als aparte overload
-- naast de nieuwe bestaan.
-- ============================================================================
drop function if exists fn_statistieken();

create function fn_statistieken(
    p_vanaf       date default null,
    p_tot         date default null,
    p_activiteit  text default null,
    p_sessie_id   uuid default null,
    p_groepering  text default 'dag'   -- 'dag' | 'week'
)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
    with basis as (
        select c.gescand_op, c.activiteit, c.clubsessie_id,
               l.id as lid_id, l.geboortejaar, l.postcode, l.herkomst
        from checkins c
        join leden l on l.id = c.lid_id
        where c.status = 'toegewezen' and c.soort = 'check_in'
          and (p_vanaf is null or c.gescand_op::date >= p_vanaf)
          and (p_tot   is null or c.gescand_op::date <= p_tot)
          and (p_activiteit is null or c.activiteit = p_activiteit)
          and (p_sessie_id  is null or c.clubsessie_id = p_sessie_id)
    ),
    tijdlijn_ruw as (
        select
            (case when p_groepering='week' then date_trunc('week', b.gescand_op)::date
                  else b.gescand_op::date end) as bucket,
            coalesce(a.naam, b.activiteit, 'onbekend') as activiteit_naam,
            count(*) as aantal
        from basis b
        left join activiteiten a on a.code = b.activiteit
        group by 1, 2
    ),
    tijdlijn as (
        select jsonb_agg(jsonb_build_object(
            'periode_label', case when p_groepering='week'
                then 'wk ' || to_char(bucket,'DD/MM')
                else to_char(bucket,'DD/MM') end,
            'periode_sort', bucket,
            'activiteit', activiteit_naam,
            'aantal', aantal
        ) order by bucket, activiteit_naam)
        from tijdlijn_ruw
    ),
    leden_gefilterd as (
        select distinct lid_id, geboortejaar, postcode, herkomst from basis
    ),
    leeftijd_emmers as (
        select
            case
                when geboortejaar is null then 'onbekend'
                when (extract(year from current_date)::int - geboortejaar) <= 12 then '0-12'
                when (extract(year from current_date)::int - geboortejaar) <= 17 then '13-17'
                when (extract(year from current_date)::int - geboortejaar) <= 25 then '18-25'
                when (extract(year from current_date)::int - geboortejaar) <= 35 then '26-35'
                when (extract(year from current_date)::int - geboortejaar) <= 50 then '36-50'
                when (extract(year from current_date)::int - geboortejaar) <= 65 then '51-65'
                else '66+'
            end as emmer,
            case
                when geboortejaar is null then 8
                when (extract(year from current_date)::int - geboortejaar) <= 12 then 1
                when (extract(year from current_date)::int - geboortejaar) <= 17 then 2
                when (extract(year from current_date)::int - geboortejaar) <= 25 then 3
                when (extract(year from current_date)::int - geboortejaar) <= 35 then 4
                when (extract(year from current_date)::int - geboortejaar) <= 50 then 5
                when (extract(year from current_date)::int - geboortejaar) <= 65 then 6
                else 7
            end as volgorde
        from leden_gefilterd
    ),
    leeftijd as (
        select jsonb_agg(jsonb_build_object('label', emmer, 'aantal', aantal) order by volgorde)
          from (select emmer, volgorde, count(*) as aantal from leeftijd_emmers group by emmer, volgorde) x
    ),
    postcode as (
        select jsonb_agg(jsonb_build_object('label', label, 'aantal', aantal) order by aantal desc)
          from (
              select coalesce(nullif(trim(postcode), ''), 'onbekend') as label, count(*) as aantal
              from leden_gefilterd group by 1
          ) x
    ),
    herkomst as (
        select jsonb_agg(jsonb_build_object('label', label, 'aantal', aantal) order by aantal desc)
          from (
              select coalesce(nullif(trim(herkomst), ''), 'onbekend') as label, count(*) as aantal
              from leden_gefilterd group by 1
          ) x
    ),
    activiteiten as (
        select jsonb_agg(jsonb_build_object('label', label, 'aantal', aantal) order by aantal desc)
          from (
              select coalesce(a.naam, b.activiteit, 'onbekend') as label, count(*) as aantal
              from basis b
              left join activiteiten a on a.code = b.activiteit
              group by 1
          ) x
    )
    select jsonb_build_object(
        'tijdlijn', coalesce((select * from tijdlijn), '[]'::jsonb),
        'leeftijd', coalesce((select * from leeftijd), '[]'::jsonb),
        'postcode', coalesce((select * from postcode), '[]'::jsonb),
        'herkomst', coalesce((select * from herkomst), '[]'::jsonb),
        'activiteiten', coalesce((select * from activiteiten), '[]'::jsonb)
    );
$$;

comment on function fn_statistieken is
    'Anonieme, gegroepeerde statistieken (tijdlijn per dag/week + leeftijd/postcode/herkomst/deelnames), filterbaar op periode/activiteit/sessie. Nooit individuele leden identificeerbaar.';

grant execute on function fn_statistieken(date, date, text, uuid, text) to anon;
