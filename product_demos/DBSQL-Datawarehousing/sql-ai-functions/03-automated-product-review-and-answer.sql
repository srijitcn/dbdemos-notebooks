-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 3/ Automated product review and classification with SQL functions
-- MAGIC
-- MAGIC
-- MAGIC In this demo, we will explore the SQL AI function `ai_query` to create a pipeline extracting product review information.
-- MAGIC
-- MAGIC <img src="https://raw.githubusercontent.com/databricks-demos/dbdemos-resources/main/images/product/sql-ai-functions/sql-ai-function-flow.png" width="1000">
-- MAGIC
-- MAGIC <!-- Collect usage data (view). Remove it to disable collection. View README for more details.  -->
-- MAGIC <img width="1px" src="https://www.google-analytics.com/collect?v=1&gtm=GTM-NKQ8TT7&tid=UA-163989034-1&cid=555&aip=1&t=event&ec=field_demos&ea=display&dp=%2F42_field_demos%2Ffeatures%2Fsql_ai_functions%2Freviews&dt=DBSQL">

-- COMMAND ----------

-- MAGIC %md
-- MAGIC To run this notebook, connect to <b> SQL endpoint </b>. The AI_QUERY function is available on Databricks SQL Pro and Serverless.

-- COMMAND ----------

SELECT assert_true(current_version().dbsql_version is not null, 'YOU MUST USE A SQL WAREHOUSE')

-- COMMAND ----------

USE CATALOG main;
USE SCHEMA dbdemos_ai_query;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC
-- MAGIC ## Simplifying AI function access for SQL users (*CHANGE THIS IMAGE)
-- MAGIC
-- MAGIC As reminder, `ai_query` signature is the following:
-- MAGIC
-- MAGIC ```, request
-- MAGIC SELECT ai_query(<Endpoint Name>,
-- MAGIC                 <prompt>)
-- MAGIC ```
-- MAGIC
-- MAGIC In the [previous notebook]($./02-Generate-fake-data-with-AI-functions-Foundation-Model), we created a wrapper `ASK_LLM_MODEL` function to simplify our SQL operation and hide the configuration details to end-users. We will re-use this function for this pipeline.
-- MAGIC
-- MAGIC <img src="https://raw.githubusercontent.com/databricks-demos/dbdemos-resources/main/images/product/sql-ai-functions/sql-ai-function-review-wrapper.png" width="1200px">
-- MAGIC
-- MAGIC In order to simplify the user-experience for our analysts, we will build prescriptive SQL functions that ask natural language questions of our data and return the responses as structured data.

-- COMMAND ----------

-- DBTITLE 1,Review our raw data
SELECT * FROM fake_reviews INNER JOIN fake_customers using (customer_id)

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Review analysis with prompt engineering 
-- MAGIC &nbsp;
-- MAGIC The keys to getting useful results back from a LLM model are:
-- MAGIC - Asking it a well-formed question
-- MAGIC - Being specific about the type of answer that you are expecting
-- MAGIC
-- MAGIC In order to get results in a form that we can easily store in a table, we'll ask the model to return the result in a string that reflects `JSON` representation, and be very specific of the schema that we expect
-- MAGIC
-- MAGIC Here's the prompt we've settled on:
-- MAGIC ```
-- MAGIC A customer left a review on a product. We want to follow up with anyone who appears unhappy.
-- MAGIC Extract all entities mentioned. For each entity:
-- MAGIC - classify sentiment as ["POSITIVE","NEUTRAL","NEGATIVE"]
-- MAGIC - whether customer requires a follow-up: Y or N
-- MAGIC - reason for requiring followup
-- MAGIC
-- MAGIC Return JSON ONLY. No other text outside the JSON. JSON format:
-- MAGIC [{
-- MAGIC     "product_name": <product name>,
-- MAGIC     "category": <product category>,
-- MAGIC     "sentiment": <review sentiment, one of ["POSITIVE","NEUTRAL","NEGATIVE"]>,
-- MAGIC     "followup": <Y or N for follow up>,
-- MAGIC     "followup_reason": <reason for followup>
-- MAGIC }]
-- MAGIC
-- MAGIC Review:
-- MAGIC <insert review text here>
-- MAGIC ```

-- COMMAND ----------

-- DBTITLE 1,Create the ANNOTATE function
CREATE OR REPLACE FUNCTION ANNOTATE_REVIEW(review STRING)
    RETURNS STRUCT<product_name: STRING, entity_sentiment: STRING, followup: STRING, followup_reason: STRING>
    RETURN FROM_JSON(
      ASK_LLM_MODEL(CONCAT(
        'A customer left a review. We follow up with anyone who appears unhappy.
         extract the following information:
          - classify sentiment as ["POSITIVE","NEUTRAL","NEGATIVE"]
          - returns whether customer requires a follow-up: Y or N
          - if followup is required, explain what is the main reason

        Return JSON ONLY. No other text outside the JSON. JSON format:
        {
            "product_name": <entity name>,
            "entity_sentiment": <entity sentiment>,
            "followup": <Y or N for follow up>,
            "followup_reason": <reason for followup>
        }
        
        Review:', review)),
      "STRUCT<product_name: STRING, entity_sentiment: STRING, followup: STRING, followup_reason: STRING>")
    

-- COMMAND ----------

-- DBTITLE 1,Extract information from all our reviews
CREATE OR REPLACE TABLE reviews_annotated as 
    SELECT * EXCEPT (review_annotated), review_annotated.* FROM (
      SELECT *, ANNOTATE_REVIEW(review) AS review_annotated
        FROM fake_reviews LIMIT 10)
    INNER JOIN fake_customers using (customer_id)

-- COMMAND ----------

SELECT * FROM reviews_annotated

-- COMMAND ----------

CREATE OR REPLACE FUNCTION GENERATE_RESPONSE(firstname STRING, lastname STRING, article_this_year INT, product STRING, reason STRING)
  RETURNS STRING
  RETURN ASK_LLM_MODEL(
    CONCAT("Our customer named ", firstname, " ", lastname, " who ordered ", article_this_year, " articles this year was unhappy about ", product, 
    "specifically due to ", reason, ". Provide an empathetic message I can send to my customer 
    including the offer to have a call with the relevant product manager to leave feedback. I want to win back their 
    favour and I do not want the customer to churn")
  )

-- COMMAND ----------

SELECT GENERATE_RESPONSE("Quentin", "Ambard", 235, "Country Choice Snacking Cookies", "Quality issue") AS customer_response

-- COMMAND ----------

CREATE OR REPLACE TABLE reviews_answer as 
    SELECT *,
      GENERATE_RESPONSE(firstname, lastname, order_count, product_name, followup_reason) AS response_draft
    FROM reviews_annotated where followup='Y'
    LIMIT 10

-- COMMAND ----------

SELECT * FROM reviews_answer

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Going further
-- MAGIC
-- MAGIC Our pipeline is ready. Keep in mind that this is a fairly basic pipeline for our demo.
-- MAGIC
-- MAGIC For more advanced pipeline, we recommend using Delta Live Table. DLT simplify data ingetsion and transformation tasks with incremental load, materialized view and more advanced features suck as MERGE operation or CDC and SCDT2. For more details, run `dbdemos.install_demo('dlt-loans')`

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Extra: AdHoc Queries
-- MAGIC
-- MAGIC Remember that analysts can always use the `ASK_LLM_MODEL()` function we created earlier to apply their own prompts to the data.
-- MAGIC
-- MAGIC As short example, let's write a query to extract all review about beverages:

-- COMMAND ----------

SELECT review_id,
    BOOLEAN(ASK_LLM_MODEL(
      CONCAT("Does this review discuss beverages? Answer boolean: 'true' or 'false' only, lowercase, no explanations or notes nor final dot. Review: ", review)
    )) AS is_beverage_review,
    review
  FROM dbdemos.openai_demo.fake_reviews LIMIT 10

-- COMMAND ----------

SELECT review_id,
    ai_query(
    "databricks-mpt-30b-instruct",
      CONCAT("Does this review discuss beverages? Answer boolean: 'true' or 'false' only, lowercase, no explanations or notes nor final dot. Review: ", review)
    ) AS is_beverage_review,
    review
  FROM dbdemos.openai_demo.fake_reviews LIMIT 10

-- COMMAND ----------

SELECT review_id,
    review,
    ai_query(
    "databricks-mpt-30b-instruct",
      CONCAT("Does this review discuss beverages? Answer boolean: 'true' or 'false' only, lowercase, no explanations or notes nor final dot. Review: ", review)
    ) AS is_beverage_review
  FROM dbdemos.openai_demo.fake_reviews LIMIT 10

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## You're now ready to process your text using external LLM models!
-- MAGIC
-- MAGIC We've seen that the lakehouse provide advanced AI capabilities, not only you can leverage external LLM APIs, but you can also build your own LLM with dolly!
-- MAGIC For more details on creating your chatbot with the Lakehouse, run: `dbdemos.install('llm-dolly-chatbot')`
-- MAGIC
-- MAGIC Go back to [the introduction]($./01-SQL-AI-Functions-Introduction)
