# Identity stack (`vt-identity`)

The three IAM roles the PEP depends on, in one stack. It creates new roles and never modifies existing ones.

| Role | PEP setting | Used by | Permissions |
| --- | --- | --- | --- |
| `<prefix>-OIDCRole` | `OIDC_ROLE_ARN` | Plane A bootstrap. Assumed with the user's Entra ID token. | `sso-oauth:CreateTokenWithIAM` only |
| `<prefix>-IdEnhancedRole` (carrier) | `TIP_ROLE_ARN` | Plane B data access on the user's behalf | Lake Formation `GetDataAccess`, Athena (one workgroup), Glue catalog read, S3 Access Grants, Redshift Serverless Data API, optional Athena results bucket |
| `<prefix>-PepServiceRole` | Fargate **task role** | The PEP's ambient identity | May only assume the carrier role (`sts:AssumeRole`, `SetContext`, `SetSourceIdentity`). No data permissions. |

The carrier role has **no Bedrock permission**. Model calls are made by the AgentCore Runtime agent under its own execution role (see the root `template.yaml` / `main.tf`).

```
Entra ID token -> OIDCRole (CreateTokenWithIAM) -> identity context
PepServiceRole (Fargate task role) --AssumeRole + SetContext--> IdEnhancedRole -> Lake Formation / Athena
```

## Files

| File | Description |
| --- | --- |
| `vt-identity-stack.yml` | CloudFormation stack |
| `vt-identity/` | Terraform equivalent (used as a module by the root `main.tf`) |

## Parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `NamePrefix` | `vt` | Prefix for role names |
| `OidcProviderArn` | required | Existing IAM OIDC provider, e.g. `arn:aws:iam::<acct>:oidc-provider/login.microsoftonline.com/<tenant>/v2.0`. Referenced, not created. |
| `OidcAudiences` | required | Entra client IDs accepted by the OIDC role, **comma-separated on one line** (no spaces or line breaks) |
| `AthenaWorkGroup` | `idc-wg` | Must match the PEP's `ATHENA_WORKGROUP` |
| `AthenaResultsBucketName` | empty | **Bucket name only** (no `s3://`). Needed only when the caller, not the workgroup, writes results. |
| `RedshiftWorkgroupName` | `*` | Redshift Serverless workgroup for the Data API |
| `AllowOidcRoleToAssumeCarrier` | `false` | Legacy single-call exchange only; the PEP does not need it |
| `TrustEcsTasks` | `true` | Let ECS tasks assume the PEP base role |
| `LocalDevPrincipalArns` | empty | IAM users/roles allowed to assume the PEP base role for local runs. Leave empty when deployed. |
| `LocalDevRequireMfa` | `false` | Require MFA for those local principals |

## Deploy

CloudFormation:

```
aws cloudformation create-stack --stack-name vt-identity --region us-east-1 \
  --template-body file://iam/vt-identity-stack.yml --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=OidcProviderArn,ParameterValue=arn:aws:iam::<acct>:oidc-provider/login.microsoftonline.com/<tenant>/v2.0 \
    ParameterKey=OidcAudiences,ParameterValue="<client-id-1>,<client-id-2>"
```

A stack that failed on creation stays in `ROLLBACK_COMPLETE`; delete it before creating it again.

Terraform: the root `main.tf` calls `./iam/vt-identity` as a module, so no separate step is needed. To use it alone:

```
cd iam/vt-identity
terraform init
terraform apply -var 'oidc_provider_arn=arn:aws:iam::<acct>:oidc-provider/login.microsoftonline.com/<tenant>/v2.0' \
                -var 'oidc_audiences=["<client-id-1>","<client-id-2>"]'
```

## Outputs

| Output | Use as |
| --- | --- |
| `OidcRoleArn` / `oidc_role_arn` | `OIDC_ROLE_ARN` |
| `EnhancedRoleArn` / `enhanced_role_arn` | `TIP_ROLE_ARN` (carrier role) |
| `PepServiceRoleArn` / `pep_service_role_arn` | Fargate task role |

The CloudFormation stack also exports these as `<stack-name>-oidc-role-arn`, `<stack-name>-enhanced-role-arn` and `<stack-name>-pep-service-role-arn`. The root `template.yaml` imports them through its `IdentityStackName` parameter (default `vt-identity`).
