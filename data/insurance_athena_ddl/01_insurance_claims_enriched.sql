-- Replace YOUR_BUCKET_NAME with your S3 bucket name.
-- Database: insurance_analytics
-- CSV column order matches the user-supplied 55-column header, including _c39.
-- _c39 is an unused extra source column and can be dropped after conversion to Parquet.
-- The enrichment script appends synthetic columns in the order shown.
-- If you have a different input CSV layout, adjust the columns before loading.
-- Date values remain STRING because Athena's OpenCSVSerde does not directly
-- parse ISO-8601 (YYYY-MM-DD) DATE fields.

-- CREATE DATABASE IF NOT EXISTS insurance_analytics  LOCATION 's3://vt-sample-data-bucket/insurance-analytics/';
CREATE EXTERNAL TABLE `insurance_claims_enriched`(
  `months_as_customer` bigint, 
  `age` bigint, 
  `policy_number` bigint, 
  `policy_bind_date` string, 
  `policy_state` string, 
  `policy_csl` string, 
  `policy_deductable` bigint, 
  `policy_annual_premium` double, 
  `umbrella_limit` bigint, 
  `insured_zip` bigint, 
  `insured_sex` string, 
  `insured_education_level` string, 
  `insured_occupation` string, 
  `insured_hobbies` string, 
  `insured_relationship` string, 
  `capital-gains` bigint, 
  `capital-loss` bigint, 
  `incident_date` string, 
  `incident_type` string, 
  `collision_type` string, 
  `incident_severity` string, 
  `authorities_contacted` string, 
  `incident_state` string, 
  `incident_city` string, 
  `incident_location` string, 
  `incident_hour_of_the_day` bigint, 
  `number_of_vehicles_involved` bigint, 
  `property_damage` string, 
  `bodily_injuries` bigint, 
  `witnesses` bigint, 
  `police_report_available` string, 
  `total_claim_amount` bigint, 
  `injury_claim` bigint, 
  `property_claim` bigint, 
  `vehicle_claim` bigint, 
  `auto_make` string, 
  `auto_model` string, 
  `auto_year` bigint, 
  `fraud_reported` string, 
  `_c39` string, 
  `customer_id` string, 
  `claim_id` string, 
  `customer_name` string, 
  `customer_email` string, 
  `customer_phone` string, 
  `customer_address` string, 
  `customer_city` string, 
  `customer_province` string, 
  `customer_dob` string, 
  `claim_filed_date` string, 
  `claim_status` string, 
  `claim_settlement_date` string, 
  `claim_paid_amount` double, 
  `claim_outstanding_amount` double, 
  `fraud_risk_score` double)
ROW FORMAT DELIMITED 
  FIELDS TERMINATED BY ',' 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.mapred.TextInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION
  's3://vt-sample-data-bucket/insurance-analytics/insurance_claims_enriched/'
TBLPROPERTIES (
  'CRAWL_RUN_ID'='f00d64e3-08da-4a85-a271-b35e094b39d1', 
  'CrawlerSchemaDeserializerVersion'='1.0', 
  'CrawlerSchemaSerializerVersion'='1.0', 
  'UPDATED_BY_CRAWLER'='insurance_analytics', 
  'areColumnsQuoted'='false', 
  'averageRecordSize'='557', 
  'classification'='csv', 
  'columnsOrdered'='true', 
  'compressionType'='none', 
  'delimiter'=',', 
  'objectCount'='1', 
  'recordCount'='771', 
  'sizeKey'='429482', 
  'skip.header.line.count'='1', 
  'typeOfData'='file')
