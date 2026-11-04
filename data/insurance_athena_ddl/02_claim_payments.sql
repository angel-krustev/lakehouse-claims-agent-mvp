CREATE EXTERNAL TABLE `claim_payments`(
  `payment_id` string, 
  `claim_id` string, 
  `payment_date` string, 
  `payment_type` string, 
  `payment_amount` double, 
  `payment_status` string, 
  `payee_name` string, 
  `payee_account` string, 
  `payment_method` string)
ROW FORMAT DELIMITED 
  FIELDS TERMINATED BY ',' 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.mapred.TextInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION
  's3://vt-sample-data-bucket/insurance-analytics/claim_payments/'
TBLPROPERTIES (
  'CRAWL_RUN_ID'='f00d64e3-08da-4a85-a271-b35e094b39d1', 
  'CrawlerSchemaDeserializerVersion'='1.0', 
  'CrawlerSchemaSerializerVersion'='1.0', 
  'UPDATED_BY_CRAWLER'='insurance_analytics', 
  'areColumnsQuoted'='false', 
  'averageRecordSize'='96', 
  'classification'='csv', 
  'columnsOrdered'='true', 
  'compressionType'='none', 
  'delimiter'=',', 
  'objectCount'='1', 
  'recordCount'='1466', 
  'sizeKey'='140766', 
  'skip.header.line.count'='1', 
  'typeOfData'='file')
