-- Attaches campaign, advertiser and parent advertiser to each billing
-- adjustment, so adjustments can be rolled up to brand on the same terms as
-- revenue without a chain of joins at report time.
--
-- Adjustments are recorded at campaign x month, which is the grain the business
-- rule fixes them at, so nothing here changes their grain or their value.

with stg_billing_adjustments as (

    select * from {{ ref('stg_billing_adjustments') }}

),

stg_campaigns as (

    select * from {{ ref('stg_campaigns') }}

),

int_advertisers_with_parent as (

    select * from {{ ref('int_advertisers_with_parent') }}

),

final as (

    select
        adjustments.campaign_id,
        campaigns.advertiser_id,
        advertisers.parent_advertiser_id,
        adjustments.billing_month,
        adjustments.adjustment_usd,
        adjustments.reason
    from stg_billing_adjustments as adjustments
    left join stg_campaigns as campaigns
        on adjustments.campaign_id = campaigns.campaign_id
    left join int_advertisers_with_parent as advertisers
        on campaigns.advertiser_id = advertisers.advertiser_id

)

select * from final
