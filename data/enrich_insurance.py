import argparse
from datetime import date, timedelta
from pathlib import Path
import numpy as np
import pandas as pd
from faker import Faker


def enrich(input_csv: str, output_csv: str, payments_csv: str, seed: int = 42) -> None:
    rng = np.random.default_rng(seed)
    fake = Faker('en_CA')
    Faker.seed(seed)
    df = pd.read_csv(input_csv)
    if 'total_claim_amount' not in df.columns:
        raise ValueError('Expected a total_claim_amount column in insurance_claims.csv')
    if 'incident_date' not in df.columns:
        raise ValueError('Expected an incident_date column in insurance_claims.csv')

    n = len(df)
    incident_dates = pd.to_datetime(df['incident_date'], errors='coerce')
    if incident_dates.isna().any():
        raise ValueError('Some incident_date values could not be parsed')
    amounts = pd.to_numeric(df['total_claim_amount'], errors='coerce')
    if amounts.isna().any() or (amounts < 0).any():
        raise ValueError('total_claim_amount must contain valid nonnegative amounts')

    # Stable per-row identifiers and fictional PII; the source dataset is preserved.
    df['customer_id'] = [f'CUST{i:06d}' for i in range(1, n + 1)]
    df['claim_id'] = [f'CLM{i:06d}' for i in range(1, n + 1)]
    df['customer_name'] = [fake.name() for _ in range(n)]
    df['customer_email'] = [f'customer{i:06d}@example.com' for i in range(1, n + 1)]
    df['customer_phone'] = [f'416-555-{i % 10000:04d}' for i in range(n)]
    df['customer_address'] = [f'{i+100} Example Street' for i in range(n)]
    provinces = {'Toronto':'ON','Ottawa':'ON','Vancouver':'BC','Calgary':'AB','Montreal':'QC','Halifax':'NS'}
    cities = rng.choice(list(provinces), n)
    df['customer_city'] = cities
    df['customer_province'] = [provinces[city] for city in cities]

    # Ages in the original dataset are used to keep dates of birth consistent.
    ages = pd.to_numeric(df['age'], errors='coerce') if 'age' in df else pd.Series(np.nan, index=df.index)
    reference_dates = incident_dates
    years = ages.fillna(40).clip(lower=18, upper=95).astype(int)
    # Approximate dob relative to incident date so original age is approximately preserved.
    df['customer_dob'] = [(dt.date() - timedelta(days=int(age) * 365 + int(rng.integers(0, 365)))).isoformat()
                          for dt, age in zip(reference_dates, years)]

    filed_lag = rng.integers(1, 15, size=n)
    filed_dates = incident_dates + pd.to_timedelta(filed_lag, unit='D')
    df['claim_filed_date'] = filed_dates.dt.strftime('%Y-%m-%d')

    # A reproducible synthetic workflow, not actual claim outcomes.
    status = rng.choice(['Approved','Pending','Rejected','Under Review'], size=n, p=[0.55, 0.20, 0.10, 0.15])
    df['claim_status'] = status
    settle_days = rng.integers(7, 91, size=n)
    settlement_dates = filed_dates + pd.to_timedelta(settle_days, unit='D')
    df['claim_settlement_date'] = [dt.strftime('%Y-%m-%d') if s == 'Approved' else ''
                                   for dt, s in zip(settlement_dates, status)]
    fractions = rng.uniform(0.55, 1.0, size=n)
    paid = np.where(status == 'Approved', np.minimum(amounts.to_numpy(), np.round(amounts.to_numpy() * fractions, 2)), 0.0)
    # Outstanding only on open claims; rejected claims are zero payable, approved claims are closed.
    outstanding = np.where(np.isin(status, ['Pending','Under Review']), amounts.to_numpy(), 0.0)
    df['claim_paid_amount'] = np.round(paid, 2)
    df['claim_outstanding_amount'] = np.round(outstanding, 2)
    df['fraud_risk_score'] = np.round(rng.beta(2, 5, n), 3)

    # Create one-to-many payment transactions. Completed payments reconcile to
    # claim_paid_amount *to the cent*. Non-approved claims have no completed payments.
    payment_rows = []
    payee_types = ['Repair Shop', 'Policyholder', 'Medical Provider', 'Body Shop']
    methods = ['EFT', 'Cheque', 'Direct Deposit']
    for i in range(n):
        claim_id = df.iloc[i]['claim_id']
        filed = filed_dates.iloc[i].date()
        if status[i] == 'Approved':
            settlement = settlement_dates.iloc[i].date()
            total_cents = int(round(float(paid[i]) * 100))
            if total_cents <= 0:
                continue
            # Typically 2-3 transactions per paid claim; handle small values.
            count = min(int(rng.integers(2, 4)), total_cents)
            cuts = sorted(rng.choice(np.arange(1, total_cents), size=count - 1, replace=False).tolist()) if count > 1 and total_cents <= 100000 else None
            if cuts is None and count > 1:
                weights = rng.dirichlet(np.ones(count))
                parts = np.maximum(1, np.floor(weights * (total_cents - count)).astype(int) + 1)
                parts[-1] += total_cents - int(parts.sum())
                # Correct rare over-allocation from rounding.
                if parts[-1] < 1:
                    parts = np.array([total_cents // count] * count)
                    parts[-1] += total_cents - int(parts.sum())
            elif count > 1:
                parts = np.diff([0] + cuts + [total_cents])
            else:
                parts = [total_cents]
            day_span = max(0, (settlement - filed).days)
            offsets = sorted(rng.integers(0, day_span + 1, size=count))
            for cents, offset in zip(parts, offsets):
                idx = len(payment_rows) + 1
                payment_rows.append({
                    'payment_id': f'PAY{idx:07d}', 'claim_id': claim_id,
                    'payment_date': (filed + timedelta(days=int(offset))).isoformat(),
                    'payment_type': str(rng.choice(['Repair', 'Medical', 'Injury', 'Settlement'])),
                    'payment_amount': round(int(cents) / 100, 2),
                    'payment_status': 'Completed',
                    'payee_name': f'{rng.choice(payee_types)} {int(rng.integers(100, 999))}',
                    'payee_account': f'****{int(rng.integers(0, 10000)):04d}',
                    'payment_method': str(rng.choice(methods)),
                })
        elif status[i] in ['Pending', 'Under Review'] and rng.random() < 0.35:
            # Administrative payment requests (no money disbursed).
            idx = len(payment_rows) + 1
            payment_rows.append({
                'payment_id': f'PAY{idx:07d}', 'claim_id': claim_id,
                'payment_date': filed.isoformat(),
                'payment_type': 'Settlement', 'payment_amount': 0.0,
                'payment_status': 'Pending',
                'payee_name': f'Policyholder {i + 1}',
                'payee_account': f'****{int(rng.integers(0, 10000)):04d}',
                'payment_method': 'EFT',
            })

    payment_columns = ['payment_id', 'claim_id', 'payment_date', 'payment_type',
                       'payment_amount', 'payment_status', 'payee_name',
                       'payee_account', 'payment_method']
    payments = pd.DataFrame(payment_rows, columns=payment_columns)
    totals = payments.loc[payments['payment_status'].eq('Completed')].groupby('claim_id')['payment_amount'].sum()
    expected = pd.Series(np.round(paid, 2), index=df['claim_id'].to_numpy())
    differences = expected.sub(totals.reindex(expected.index, fill_value=0)).abs()
    if (differences > 0.001).any():
        raise AssertionError('Payment reconciliation failed for claims: ' + ', '.join(differences[differences > 0.001].index[:5]))
    if not payments['claim_id'].isin(df['claim_id']).all():
        raise AssertionError('Orphan claim payments detected')

    Path(payments_csv).parent.mkdir(parents=True, exist_ok=True)
    payments.to_csv(payments_csv, index=False)
    print(f'Saved {len(payments):,} payments to {payments_csv}')

    Path(output_csv).parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(output_csv, index=False)
    print(f'Saved {n:,} enriched claims to {output_csv}')
    print(df[['claim_id','customer_name','claim_status','claim_paid_amount','fraud_risk_score']].head())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Enrich an insurance claims CSV with synthetic PII and workflow fields.')
    parser.add_argument('input_csv', nargs='?', default='insurance_claims.csv')
    parser.add_argument('--output', default='insurance_claims_enriched.csv')
    parser.add_argument('--payments-output', default='claim_payments.csv')
    parser.add_argument('--seed', type=int, default=42)
    args = parser.parse_args()
    enrich(args.input_csv, args.output, args.payments_output, args.seed)
