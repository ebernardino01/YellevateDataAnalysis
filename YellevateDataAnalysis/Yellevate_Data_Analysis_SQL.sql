/*--------------------------------------------
    DATA CLEANING
    1. Loading of CSV file to table
    2. Data validations
    3. Data transformations
*/--------------------------------------------

/* 
    Create invoices table
    Once table is created, import data from the CSV file
*/
DROP TABLE IF EXISTS invoices;
CREATE TABLE IF NOT EXISTS invoices (
    country VARCHAR(50),
    customer_id VARCHAR(16),
    invoice_number BIGINT UNIQUE NOT NULL,
    invoice_generated_date DATE,
    invoice_due_date DATE,
    invoice_amount INTEGER,
    disputed BOOLEAN,
    dispute_lost BOOLEAN,
    invoice_settled_date DATE,
    days_to_settle INTEGER,
    days_late INTEGER
);

/*
    Verify if all rows from the CSV file were successfully
    loaded to the table
*/
WITH table_shape AS 
(
    SELECT
        (
            SELECT
                COUNT(invoice_number) AS row_count
            FROM
                invoices
        ),
        (
            SELECT
                COUNT(*) AS column_count
            FROM
                information_schema.columns
            WHERE 
                table_name = 'invoices'
        )
)
SELECT * FROM table_shape;


/*
    For each table columns, check for the following:
    - null values
    - distinct values count
    - most common values

    Exclude columns with all values being unique
    (n_distinct = -1)

    Source: https://www.postgresql.org/docs/current/view-pg-stats.html
*/
WITH stats AS (
    SELECT
        information_schema.columns.ordinal_position as column_number,
        pg_stats.attname AS column_name,
        format_type(atttypid, atttypmod) AS data_type,
        null_frac,
        n_distinct,
        most_common_vals
    FROM
        pg_stats
    JOIN
        pg_attribute
    ON
        pg_stats.attname = pg_attribute.attname
    JOIN
        pg_type
    ON
        pg_attribute.atttypid = pg_type.oid
    JOIN
        information_schema.columns
    ON
        information_schema.columns.column_name = pg_stats.attname
    WHERE
        tablename = 'invoices'
    AND
        n_distinct != -1
),
categorized AS (
    SELECT
        column_number,
        column_name,
        (null_frac * 100)::numeric(10, 2) AS null_percentage,
        n_distinct::numeric(10, 2) AS distinct_count,
        most_common_vals,
        CASE 
            WHEN
                data_type = ANY('{integer, bigint}')
                THEN 'numeric'
            WHEN
                data_type = ANY('{date}')
                THEN 'timestamp'
            ELSE
                'categorical'
        END AS category
    FROM
        stats
)
SELECT
    column_number,
    column_name,
    category,
    null_percentage,
    distinct_count,
    most_common_vals
FROM
    categorized
ORDER BY
    column_number;



/* Additional business logic verification */
SELECT
    *
FROM
    invoices
WHERE
    disputed = false AND
    dispute_lost = true;


/* Prepare new columns to hold the transformed values */
ALTER TABLE
    invoices
ADD COLUMN
    invoice_status varchar(50),
ADD COLUMN
    invoice_dispute_resolution varchar(50);

/*
    Transform the dispute columns into less technical values
    * disputed (0/false, 1/true)
        -> invoice_status ('Accepted', 'Disputed')
    * dispute_lost (0/false, 1/true)
        -> invoice_dispute_resolution ('In favor of Yellevate',
            'In favor of Customer')
*/
UPDATE invoices
SET 
    invoice_status = 
    CASE
        WHEN disputed = true
            THEN 'Disputed'
        ELSE 'Accepted'
    END,
    invoice_dispute_resolution = 
    CASE
        WHEN dispute_lost = true
            THEN 'In favor of Customer'
        ELSE 'In favor of Yellevate'
    END;

/* Drop the initial boolean columns */
ALTER TABLE
    invoices
DROP COLUMN
    disputed,
DROP COLUMN
    dispute_lost;


/*--------------------------------------------
    DATA ANALYSIS GOALS Summary
    - SQL command to show all answers
    as single resultset
*/--------------------------------------------
WITH data_analysis_goals AS
(
    SELECT
        /*
        1) The processing time in which invoices are settled (average # 
        of days rounded to a whole number)
        */
        (
            WITH settlement_time AS (
                SELECT
                    ROUND(AVG(days_to_settle), 0) AS average, 
                    ROUND(MIN(days_to_settle), 0) AS minimum,
                    ROUND(MAX(days_to_settle), 0) AS maximum
                FROM
                    invoices
            )
            SELECT
                average AS average_invoice_settlement_time
            FROM
                settlement_time
        ),
        /*
        2) The processing time for the company to settle disputes (average 
        # of days rounded to a whole number)
        */
        (
            WITH dispute_settlement_time AS (
                SELECT
                    ROUND(AVG(days_to_settle), 0) AS average, 
                    ROUND(MIN(days_to_settle), 0) AS minimum,
                    ROUND(MAX(days_to_settle), 0) AS maximum
                FROM
                    invoices
                WHERE
                    invoice_status = 'Disputed'
            )
            SELECT
                average AS average_dispute_settlement_time
            FROM
                dispute_settlement_time
        ),
        /*
        3) Percentage of disputes received by the company that were lost 
        (within two decimal places)
        */
        (
            WITH disputes_count AS (
                SELECT
                    invoice_dispute_resolution,
                    COUNT(invoice_number) as invoice_count,
                    ROUND(
                        (COUNT(invoice_number) * 100) / (SUM(COUNT(invoice_number)) OVER () )
                    , 2) AS percentage_disputes_lost
                FROM
                    invoices
                WHERE
                    invoice_status = 'Disputed'
                GROUP BY
                    invoice_dispute_resolution
            )
            SELECT
                percentage_disputes_lost
            FROM
                disputes_count
            WHERE
                invoice_dispute_resolution = 'In favor of Customer'
        ),
        /*
        4) Percentage of revenue lost from disputes (within two decimal 
        places)
        */
        (
            WITH disputes_sum AS (
                SELECT
                    invoice_dispute_resolution,
                    SUM(invoice_amount) as invoice_amount,
                    ROUND(
                        (SUM(invoice_amount) * 100) / (SUM(SUM(invoice_amount)) OVER () )
                    , 2) AS percentage_revenue_lost_disputes
                FROM
                    invoices
                WHERE
                    invoice_status = 'Disputed'
                GROUP BY
                    invoice_dispute_resolution
            )
            SELECT
                percentage_revenue_lost_disputes
            FROM
                disputes_sum
            WHERE
                invoice_dispute_resolution = 'In favor of Customer'
        ),
        /*
        5) The country where the company reached the highest losses from 
        lost disputes (in USD)
        */
        (
            WITH revenue_lost AS (
                SELECT
                    country,
                    SUM(invoice_amount) AS invoice_amount,
                    COUNT(invoice_number) AS number_of_invoices
                FROM
                    invoices
                WHERE
                    invoice_status = 'Disputed' AND
                    invoice_dispute_resolution = 'In favor of Customer'
                GROUP BY
                    country
                ORDER BY
                    2 DESC
            )
            SELECT
                country AS top_country_revenue_loss
            FROM
                revenue_lost
            LIMIT 1
        )
)
SELECT * FROM data_analysis_goals;
