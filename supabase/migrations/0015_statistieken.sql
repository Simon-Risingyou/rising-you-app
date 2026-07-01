-- ============================================================================
-- Rising You VZW — Ledenbeheer & Check-in
-- Migratie 0015: statistieksectie (admin portaal)
-- ----------------------------------------------------------------------------
-- Anonieme aantallen op leeftijd, postcode, herkomst en deelnames per
-- activiteit. Enkel GEGROEPEERDE AANTALLEN, nooit individuele rijen met
-- naam gecombineerd met leeftijd/postcode/herkomst (zie CLAUDE.md GDPR).
-- ============================================================================
create or replace function fn_statistieken()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
    with leeftijd_emmers as (
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
        from leden where actief
    ),
    leeftijd as (
        select jsonb_agg(jsonb_build_object('label', emmer, 'aantal', aantal) order by volgorde)
          from (select emmer, volgorde, count(*) as aantal from leeftijd_emmers group by emmer, volgorde) x
    ),
    postcode as (
        select jsonb_agg(jsonb_build_object('label', label, 'aantal', aantal) order by aantal desc)
          from (
              select coalesce(nullif(trim(postcode), ''), 'onbekend') as label, count(*) as aantal
              from leden where actief group by 1
          ) x
    ),
    herkomst as (
        select jsonb_agg(jsonb_build_object('label', label, 'aantal', aantal) order by aantal desc)
          from (
              select coalesce(nullif(trim(herkomst), ''), 'onbekend') as label, count(*) as aantal
              from leden where actief group by 1
          ) x
    ),
    activiteiten as (
        select jsonb_agg(jsonb_build_object('label', label, 'aantal', aantal) order by aantal desc)
          from (
              select coalesce(a.naam, c.activiteit) as label, count(*) as aantal
              from checkins c
              left join activiteiten a on a.code = c.activiteit
              where c.status = 'toegewezen' and c.soort = 'check_in'
              group by coalesce(a.naam, c.activiteit)
          ) x
    )
    select jsonb_build_object(
        'leeftijd', coalesce((select * from leeftijd), '[]'::jsonb),
        'postcode', coalesce((select * from postcode), '[]'::jsonb),
        'herkomst', coalesce((select * from herkomst), '[]'::jsonb),
        'activiteiten', coalesce((select * from activiteiten), '[]'::jsonb)
    );
$$;

comment on function fn_statistieken is
    'Anonieme aantallen (leeftijd-emmer, postcode, herkomst, deelnames per activiteit) voor het admin-portaal. Nooit individuele leden identificeerbaar.';

grant execute on function fn_statistieken() to anon;
