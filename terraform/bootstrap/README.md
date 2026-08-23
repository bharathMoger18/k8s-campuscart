# bootstrap/

## What this module is

This is a special, standalone Terraform root module with **one job**: create
the S3 bucket that every other module in `terraform/` will use to store
its state, with native S3 locking (Terraform 1.10+) handling concurrent
applies safely.

It is **not** part of the CampusCart application infrastructure itself —
you won't destroy this when you tear down EKS/RDS/etc. after testing. Think
of it as the shelf you build once, before you start putting anything on it.

## When to run this

**Exactly once**, before touching any other module. After that, you should
almost never need to touch this folder again.

## How to run this

\`\`\`bash
cd terraform/bootstrap

cp terraform.tfvars.example terraform.tfvars

# edit terraform.tfvars — set state_bucket_name to something globally unique

# (tip: aws sts get-caller-identity → use your account ID in the name)

terraform init # downloads the AWS provider plugin
terraform plan # shows you EXACTLY what will be created — read it
terraform apply # type "yes" when prompted, after reading the plan
\`\`\`

After it finishes, run:

\`\`\`bash
terraform output
\`\`\`

and copy the `state_bucket_name` value — you'll paste it into
`terraform/environments/production/backend.tf` in the next step, along with
`use_lockfile = true`, so that module (and every module after it) stores
its state remotely and locks safely, without needing DynamoDB.

## Important: this module's own state stays local

This is deliberate (explained in `provider.tf`). Do **not** add a `backend`
block here — there's a chicken-and-egg problem, since this module creates
the very bucket a remote backend would need.

That means after running `terraform apply` here, you'll have a
`terraform.tfstate` file sitting in this folder. **Do not commit it to
git** — it's already covered by the repo-wide `.gitignore`, but it's worth
understanding why: this local file is the only record of "the S3 bucket
already exists" until you've run this once. If you lose it AND the bucket
already exists, Terraform will error out trying to re-create a bucket
that's already there — recoverable, but avoidable if you just don't delete
this file carelessly.
