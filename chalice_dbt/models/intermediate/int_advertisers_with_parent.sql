-- Attaches each advertiser's parent name, so a consumer can roll up to brand
-- without joining advertisers to itself.
--
-- The source carries 7 advertiser rows that are really 5 brands: ADV-1002
-- ('northgate insurance ', lowercased with a trailing space) is ADV-1001, and
-- ADV-1004 ('Perreault Foods NA') is a division of ADV-1003. Reporting on
-- advertiser_id splits two brands across two lines each and understates
-- Perreault Foods by 53%. Carrying the parent name here means "one brand is one
-- line" is a group-by rather than a join a reader has to know to write.

with stg_advertisers as (

    select * from {{ ref('stg_advertisers') }}

),

int_parent_advertisers as (

    select * from {{ ref('int_parent_advertisers') }}

),

final as (

    select
        advertisers.advertiser_id,
        advertisers.advertiser_name,
        advertisers.parent_advertiser_id,
        parents.parent_advertiser_name
    from stg_advertisers as advertisers
    left join int_parent_advertisers as parents
        on advertisers.parent_advertiser_id = parents.parent_advertiser_id

)

select * from final
