# Insurance Claims Demo Dataset — Description and Generation

## 1. Overview

The Insurance Claims Demo Dataset is a synthetic-enriched automobile insurance dataset designed to demonstrate AI-powered data access, analytics, and identity-based authorization in an AWS data lake.

The dataset combines publicly available insurance fraud records with artificially generated customer information, claims-processing details, and payment transactions.

It is intended for demonstrating:

- Amazon Athena and AWS Lake Formation data access
- AI agents querying insurance claims and payments
- Row-level and column-level access controls
- Identity-aware authorization and Trusted Identity Propagation (TIP) scenarios
- Protection of personally identifiable information (PII)
- Insurance fraud analysis and claims-processing workflows

**All additional customer identities, contact information, workflow statuses, fraud-risk scores, and payment records are synthetic.** They do not represent real customer accounts or actual financial transactions.

## 2. Dataset Origin

The dataset is based on the publicly available `insurance_claims.csv` automobile insurance fraud dataset.

Example source:

https://github.com/nirab25/Insurance-Claim-Fraud-Detection/blob/master/insurance_claims.csv

The original dataset contains approximately 1,000 automobile insurance records covering policyholders, insurance policies, vehicle incidents, financial claim amounts, and reported fraud indicators.

The original records were extended using a custom Python script, `enrich_insurance.py`, developed for the demo.

### Dataset generation process

1. Download the original `insurance_claims.csv`.
2. Load the CSV into Python using Pandas.
3. Retain the original insurance and claim fields.
4. Add synthetic customer identifiers and Canadian-style customer information.
5. Generate claims-processing statuses, dates, and financial amounts.
6. Generate corresponding payment transactions.
7. Validate relationships and financial consistency.
8. Export the resulting CSV files.

## 3. Generated Files

| File | Description |
|---|---|
| `insurance_claims.csv` | Original public insurance fraud dataset |
| `insurance_claims_enriched.csv` | Original claims enriched with synthetic customer, workflow, and financial data |
| `claim_payments.csv` | Synthetic payment transactions associated with individual claims |

The demo generation produced approximately 1,000 enriched claims and 1,502 payment transactions.

## 4. Enriched Insurance Claims

**File:** `insurance_claims_enriched.csv`

Each row represents one automobile insurance claim, including the policyholder, insured vehicle, incident, financial loss, claim status, and customer information.

### 4.1 Original insurance policy information

The original dataset contains fields such as:

| Field | Description |
|---|---|
| `policy_number` | Insurance policy identifier |
| `policy_bind_date` | Policy effective date |
| `policy_state` | US state associated with the policy |
| `policy_annual_premium` | Annual insurance premium |
| `policy_deductable` | Policy deductible, using the original source spelling |
| `policy_csl` | Combined single limit coverage |
| `months_as_customer` | Customer tenure |
| `age` | Age of the insured individual |

### 4.2 Incident and vehicle information

| Field | Description |
|---|---|
| `incident_date` | Date of the incident |
| `incident_type` | Collision, theft, or another incident category |
| `collision_type` | Collision classification |
| `incident_severity` | Severity of damage |
| `incident_state` | US state of the incident |
| `incident_city` | City where the incident occurred |
| `number_of_vehicles_involved` | Number of vehicles involved |
| `bodily_injuries` | Number of reported injuries |
| `police_report_available` | Whether a police report is available |
| `auto_make` | Vehicle manufacturer |
| `auto_model` | Vehicle model |
| `auto_year` | Vehicle model year |

### 4.3 Claims and fraud information

| Field | Description |
|---|---|
| `total_claim_amount` | Total reported claim amount |
| `injury_claim` | Injury-related claim amount |
| `property_claim` | Property-related claim amount |
| `vehicle_claim` | Vehicle-related claim amount |
| `fraud_reported` | Original fraud indicator |

The original `fraud_reported` field is preserved rather than replaced.

### 4.4 Synthetic customer information

The enrichment script adds fictional customer attributes:

| Field | Description |
|---|---|
| `customer_id` | Generated customer identifier, e.g. `CUST000001` |
| `claim_id` | Generated claim identifier, e.g. `CLM000001` |
| `customer_name` | Fictional Canadian-style customer name |
| `customer_email` | Synthetic address using `example.com` |
| `customer_phone` | Artificial telephone number |
| `customer_address` | Fictional street address |
| `customer_city` | Canadian city |
| `customer_province` | Canadian province |
| `customer_dob` | Artificial date of birth consistent with the source age |

The city values are selected from Toronto, Ottawa, Vancouver, Calgary, Montreal, and Halifax, with matching provincial codes.

This creates realistic-looking PII fields suitable for demonstrating sensitive-data protection without using genuine customer identity information.

**Note:** The original dataset retains its US insurance and incident locations. Canadian locations are added only to the synthetic customer profile, so geographic consistency across all fields is not guaranteed.

### 4.5 Synthetic claims-processing information

| Field | Description |
|---|---|
| `claim_filed_date` | Artificial filing date |
| `claim_status` | Generated workflow status |
| `claim_settlement_date` | Generated settlement date for approved claims |
| `claim_paid_amount` | Synthetic amount paid |
| `claim_outstanding_amount` | Synthetic outstanding amount |
| `fraud_risk_score` | Randomly generated numerical risk score |

The workflow status is selected using these probabilities:

| Status | Generation probability |
|---|---:|
| Approved | 55% |
| Pending | 20% |
| Under Review | 15% |
| Rejected | 10% |

The actual counts vary with the random generation.

The filing date is generated between 1 and 14 days after the original incident date. For approved claims, settlement occurs between 7 and 90 days after filing.

For approved claims, the paid amount is selected between 55% and 100% of the total claim amount. Open claims retain their full claimed amount as outstanding; rejected and approved claims have an outstanding amount of zero under the demo's simplified accounting convention.

The `fraud_risk_score` is generated using a beta probability distribution. It is not derived from the original `fraud_reported` label and is **not the output of a trained fraud-detection model**.

## 5. Synthetic Claim Payments

**File:** `claim_payments.csv`

This file represents financial transactions associated with insurance claims.

Each record is connected to an existing insurance claim through the `claim_id` field.

| Field | Description |
|---|---|
| `payment_id` | Unique payment identifier, e.g. `PAY0000001` |
| `claim_id` | Reference to the parent insurance claim |
| `payment_date` | Generated transaction date |
| `payment_type` | Repair, Medical, Injury, or Settlement |
| `payment_amount` | Generated transaction amount |
| `payment_status` | Completed or Pending |
| `payee_name` | Fictional payment recipient |
| `payee_account` | Artificial masked account number |
| `payment_method` | EFT, Cheque, or Direct Deposit |

### Payment generation rules

For approved claims, the script generally creates two or three completed payment transactions. Their combined value exactly matches the claim's `claim_paid_amount`, to the cent.

Completed payment dates fall between the filing and settlement dates.

For Pending and Under Review claims, there is a 35% probability of creating a pending administrative payment record. Such records have a payment amount of zero and do not represent disbursed funds.

Rejected claims do not generate payment transactions.

The payment recipients are fictional representations of repair shops, policyholders, medical providers, and body shops.

## 6. Data Relationships

The enriched claims and payment files form a simple parent-child relational dataset.

```text
insurance_claims_enriched
  ├── claim_id (unique)
  ├── customer_id
  ├── customer_name
  ├── claim_status
  └── claim_paid_amount
          │
          │ 1 : many
          ▼
claim_payments
  ├── payment_id (unique)
  ├── claim_id (foreign key)
  ├── payment_date
  ├── payment_amount
  └── payment_status
```

The `claim_id` is the common identifier between the datasets.

One claim can have multiple payment transactions, while some claims have none.

The source and enriched claims contain one record per generated customer in this demo; they do not simulate customers holding multiple claims.

## 7. Generation Technology

The datasets were created using Python and the following libraries:

- **Pandas:** CSV processing and tabular transformations
- **NumPy:** Random sampling, numerical calculations, and payment allocations
- **Faker (`en_CA`):** Synthetic Canadian-style customer names
- **Python datetime:** Filing, settlement, birth, and payment date generation

The script initializes the NumPy random generator and Faker using seed `42` by default.

This supports reproducible generation when using the same input data, code, library versions, and execution order.

### Reproduction

Install dependencies:

```bash
pip install pandas numpy faker
```

Run the enrichment:

```bash
python enrich_insurance.py insurance_claims.csv
```

The script generates:

```text
insurance_claims_enriched.csv
claim_payments.csv
```

A custom random seed can also be supplied:

```bash
python enrich_insurance.py insurance_claims.csv --seed 42
```

## 8. Validation and Data Quality

The generation script implements several consistency checks.

**Input validation**

- Confirms that the original file contains `incident_date` and `total_claim_amount`.
- Verifies that incident dates can be parsed.
- Rejects invalid or negative claim amounts.

**Relationship validation**

- Checks that every generated payment references an existing claim.
- Detects orphan payment records.

**Financial validation**

- Aggregates all completed payments by `claim_id`.
- Confirms that completed payment totals reconcile with `claim_paid_amount`.
- Raises an error if reconciliation fails.

These controls make the dataset suitable for deterministic joins and demonstration queries.

## 9. Security Classification and Demo Use

The dataset contains artificial personal information in addition to the original public insurance fields.

For demonstration purposes, the following classifications can be assigned:

| Classification | Example fields |
|---|---|
| Public / General | Vehicle make, model, incident type |
| Internal | Claim status, policy details, claim amounts |
| Confidential / PII | Customer name, email, phone, address, DOB |
| Financial Sensitive | Payment amounts, payee information, masked account reference |
| Restricted / Fraud | `fraud_reported`, `fraud_risk_score` |

These are proposed demonstration classifications, not classifications supplied by the original dataset.

The datasets can be used to evaluate whether an AI agent can access only the data authorized for the identity under which it operates.

For example, a claims adjuster may be permitted to view assigned claims, while an analyst may be restricted to aggregated claim statistics without customer contact information.

Such authorization rules are not embedded in the CSV files. They must be implemented separately through AWS IAM, Lake Formation, or another applicable authorization mechanism.

## 10. Limitations

This is a demonstration dataset, not a representation of a production insurance system.

- The customer and payment information is fictional.
- Workflow statuses are randomly generated rather than based on real business decisions.
- The fraud-risk scores have no statistical relationship to the original fraud labels.
- The accounting model is simplified and does not model reserves, recovery, reversals, or all settlement scenarios.
- Synthetic Canadian customer addresses coexist with US source-policy and incident fields.
- No assigned adjuster, tenant ownership, or enterprise identity mapping is generated by the script.
- Although PII values are synthetic, the data should still be handled according to the intended security-demo classifications.

## 11. Summary

The insurance demo consists of a publicly available automobile insurance fraud dataset extended with synthetic Canadian customer profiles, claims-processing fields, and linked payment transactions.

Its purpose is to provide a realistic relational data structure with sensitive-looking information and financial records for testing AI-agent analytics, data governance, and identity-based authorization.

The enrichment process preserves the original insurance data while using reproducible Python generation logic to create fictional identity and transaction fields. Financial reconciliation and referential integrity are validated during generation.

The resulting datasets provide a foundation for demonstrating secure access to insurance information through Amazon Athena, AWS Lake Formation, and identity-aware AI applications.

