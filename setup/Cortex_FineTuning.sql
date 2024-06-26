/***************************************************************************************************
  _______           _            ____          _             
 |__   __|         | |          |  _ \        | |            
    | |  __ _  ___ | |_  _   _  | |_) | _   _ | |_  ___  ___ 
    | | / _` |/ __|| __|| | | | |  _ < | | | || __|/ _ \/ __|
    | || (_| |\__ \| |_ | |_| | | |_) || |_| || |_|  __/\__ \
    |_| \__,_||___/ \__| \__, | |____/  \__, | \__|\___||___/
                          __/ |          __/ |               
                         |___/          |___/            
Quickstart:   Tasty Bytes - Cortex Fine Tuning
Version:      v1
Author:       Kala Govindarajan
Copyright(c): 2024 Snowflake Inc. All rights reserved.
****************************************************************************************************
SUMMARY OF CHANGES
Date(yyyy-mm-dd)    Author              Comments
------------------- ------------------- ------------------------------------------------------------
2024-06-12          Kala Govindarajan      Initial Release
***************************************************************************************************/

--STEP 1 Setup Database, Schema, role, warehouse and tables

USE ROLE SYSADMIN;

/*--
 Database, schema and warehouse creation
--*/

-- create a CFT database
CREATE OR REPLACE DATABASE CFT_DB;

CREATE OR REPLACE SCHEMA CFT_DB.CFT_SCHEMA;
CREATE OR REPLACE WAREHOUSE CFT_WH AUTO_SUSPEND = 60;
-- create roles
USE ROLE securityadmin;

-- functional roles

CREATE ROLE IF NOT EXISTS CFT_ROLE COMMENT = 'Fine tuning role';
GRANT ROLE CFT_ROLE TO role SYSADMIN;
GRANT ALL ON WAREHOUSE CFT_WH TO ROLE CFT_ROLE;
--Grants
USE ROLE securityadmin;

GRANT USAGE ON DATABASE CFT_DB TO ROLE CFT_ROLE;
GRANT USAGE ON ALL SCHEMAS IN DATABASE CFT_DB TO ROLE CFT_ROLE;

GRANT ALL ON SCHEMA CFT_DB.CFT_SCHEMA TO ROLE CFT_ROLE;

GRANT OWNERSHIP ON WAREHOUSE CFT_WH TO ROLE CFT_ROLE COPY CURRENT GRANTS;


-- future grants
GRANT ALL ON FUTURE TABLES IN SCHEMA CFT_DB.CFT_SCHEMA TO ROLE CFT_ROLE;
/*--
 • File format and stage creation
--*/

USE ROLE CFT_ROLE;
USE WAREHOUSE CFT_WH;
USE DATABASE CFT_DB;
USE SCHEMA CFT_SCHEMA;


CREATE OR REPLACE STAGE DATA_s3
COMMENT = 'CFT S3 Stage Connection'
url = 's3://sfquickstarts/frostbyte_tastybytes/fine_tuning/';

--The Support emails and the various fields are added as a CSV. List and view the files in the Public S3 Bucket. 

LIST @CFT_DB.CFT_SCHEMA.DATA_s3;

--Support_Email table creation
CREATE OR REPLACE TABLE SUPPORT_EMAILS (        
            ID INTEGER,
            TIMESTAMP VARIANT,
            SENDER VARCHAR,
            SUBJECT VARCHAR,
            BODY VARCHAR,  
            LABELED_LOCATION VARCHAR,
            LABELED_TRUCK VARCHAR,        
            SUPPORT_RESPONSE VARCHAR
            );
            

-- Load data from stage into table 
COPY INTO SUPPORT_EMAILS
FROM @CFT_DB.CFT_SCHEMA.DATA_s3/CFT_QUICKSTART.csv
FILE_FORMAT = (TYPE = 'CSV' FIELD_OPTIONALLY_ENCLOSED_BY = '"' SKIP_HEADER = 1);

--Preview the data
SELECT * FROM SUPPORT_EMAILS limit 2;

-- STEP 2:Data Preparation : Creation of Training and Validation Dataset 

--Creation of a function to construct the Completion values, 
CREATE OR REPLACE FUNCTION BUILD_EXAMPLE(location STRING, truck STRING, response_body STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
CONCAT(
'{ location: ', IFF(location IS NULL, 'null', CONCAT('"', location, '"')), 
', truck: ', IFF(truck IS NULL, 'null', CONCAT('"', truck, '"')), 
', response_body: ', IFF(response_body IS NULL, 'null', CONCAT('"', REPLACE(response_body, '\n', '\\n'), '"')), '
}')
$$
;

--Split Training Dataset

CREATE OR REPLACE TABLE FINE_TUNING_TRAINING AS (
    SELECT 
        *,
        BUILD_EXAMPLE(
            LABELED_LOCATION, LABELED_TRUCK, SUPPORT_RESPONSE
        ) as GOLDEN_JSON
    FROM SUPPORT_EMAILS
    -- Split: 20% validation data, 80% training data
    WHERE ID % 10 >= 2
);

--Split Validation Dataset

CREATE OR REPLACE TABLE FINE_TUNING_VALIDATION AS (
    SELECT 
        *,
        BUILD_EXAMPLE(
            LABELED_LOCATION, LABELED_TRUCK, SUPPORT_RESPONSE
        ) as GOLDEN_JSON
    FROM SUPPORT_EMAILS
    -- Split: 20% validation data, 80% training data
    WHERE ID % 10 < 2
    
);



-- STEP 3 :  Create a fine-tuning job 
SELECT SNOWFLAKE.CORTEX.FINETUNE(
    'CREATE', 
    -- Custom model name
    'SUPPORT_MISTRAL_7B',
    -- Base model name
    'mistral-7b',
    -- Training data query
    'SELECT BODY AS PROMPT, GOLDEN_JSON AS COMPLETION FROM FINE_TUNING_TRAINING',
    -- Validation data query 
    'SELECT BODY AS PROMPT, GOLDEN_JSON AS COMPLETION FROM FINE_TUNING_VALIDATION' 
);


--Describe the properties of a fine-tuning job
Select SNOWFLAKE.CORTEX.FINETUNE(
  'DESCRIBE',
  'CortexFineTuningWorkflow_ad15c332-4343-3434-12345y476'
);

--Describe the Models

SHOW MODELS;

CREATE OR REPLACE FUNCTION ACCURACY(candidate STRING, reference STRING)
RETURNS number
LANGUAGE SQL
AS
$$
DIV0(SUM(IFF(
    EQUAL_NULL(
        reference, 
        candidate
    ),
    -- THEN
    1,
    -- ELSE
    0
)), COUNT(*))
$$
;


--Create a table that stores the output computed using the function from Fine Tuned LLM 

CREATE OR REPLACE TABLE FINE_TUNING_VALIDATION_FINETUNED AS (
    SELECT
        -- Carry over fields from source for convenience.
        ID, BODY, LABELED_TRUCK, LABELED_LOCATION,
        -- Run the custom fine-tuned LLM.
        SNOWFLAKE.CORTEX.COMPLETE(
            -- Custom model
            'SUPPORT_MISTRAL_7B', 
            body 
        ) AS RESPONSE
    FROM FINE_TUNING_VALIDATION
);



-- STEP 4: Evaluate the Output

SELECT RESPONSE FROM FINE_TUNING_VALIDATION_FINETUNED LIMIT 5;

SELECT
    LABELED_LOCATION,
    TRY_PARSE_JSON(RESPONSE):location::STRING as FINETUNED_MODEL_RESPONSE_LOCATION,
FROM FINE_TUNING_VALIDATION_FINETUNED;

SELECT
    LABELED_TRUCK,
    TRY_PARSE_JSON(RESPONSE):truck::STRING as FINETUNED_MODEL_RESPONSE_TRUCK,
FROM FINE_TUNING_VALIDATION_FINETUNED;


--Score using the Accuracy function

SELECT
    ACCURACY(TRY_PARSE_JSON(RESPONSE):location::STRING, LABELED_LOCATION) AS ACCURACY_LOCATION,
    ACCURACY(TRY_PARSE_JSON(RESPONSE):truck::STRING, LABELED_TRUCK) AS ACCURACY_TRUCK
FROM FINE_TUNING_VALIDATION_FINETUNED;



