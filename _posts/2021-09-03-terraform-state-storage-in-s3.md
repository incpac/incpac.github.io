---
layout: single
title: Terraform State Storage in S3
date: 2021-09-03
---


Something I've found myself doing a few times in the last couple of months is creating Terraform state storage in AWS for 
different projects.

Now you can do this manually. Create an S3 bucket, a DynamoDB table, and update your config. But manual's for chumps.

Here we're going to create a Terraform stack that will create the required resources, generate a Terraform file with the 
backend config, and migrate it's own state to our remote storage.

## The Code

First we need some core configuration. This includes our provider, a data source to tell us what region we're in, and a random 
string we're going to append to resource names to ensure uniqueness.

```terraform
provider "aws" {
  region = "ap-southeast-2"
}

data "aws_region" "current" {}

resource "random_string" "random" {
  length  = 16
  special = false
  upper   = false
}
```

Next we want an S3 bucket to store our state. S3 bucket names need to be globally unique, so we're going to make use of the 
random string to help us with that.

```terraform 
resource "aws_s3_bucket" "state_storage" {
  bucket = "terraform-state-storage-${random_string.random.result}"
  acl    = "private"

  versioning {
    enabled = true
  }
}
```

We can use a DynamoDB table to lock our state. This prevents someone else from using it while we're making changes. You can 
skip this if you want, however there's no real reason to unless you're cheap.

```terraform
resource "aws_dynamodb_table" "stage_locking" {
  name         = "terraform-state-locking-${random_string.random.result}"
  hash_key     = "LockID"
  billing_mode = "PAY_PER_REQUEST"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

Since we're going to store the state of this stack in the resources it creates we're going to need some backend configuration.
However, we can't use this out the gate since the bucket and table won't exist. What we're going to do is create a template of 
the backend configuration, then have Terraform create the config file iteself. Create `backend.tf.tpl` with the following.

```terraform
terraform {
  backend "s3" {
    bucket         = "${bucket_name}"
    key            = "${bucket_key}"
    dynamodb_table = "${table_name}"
    region         = "${aws_region}"
  }
}
```

To create the output file, add the following to your Terraform config.

```terraform
resource "local_file" "backend_config" {
  filename = "${path.module}/backend.tf"

  content = templatefile("${path.module}/backend.tf.tpl", {
    bucket_name = aws_s3_bucket.state_storage.bucket
    bucket_key  = "example-state-storage"
    table_name  = aws_dynamodb_table.stage_locking.name
    aws_region  = data.aws_region.current.name
  })
}
```

## The Deploy

Now you're good to `terraform init` and `terraform apply`. In the output you should see it create our backend configuration:

```
 $ terraform init

Initializing the backend...

Initializing provider plugins...
- Finding latest version of hashicorp/random...
- Finding latest version of hashicorp/aws...
- Finding latest version of hashicorp/local...
- Installing hashicorp/random v3.1.0...
- Installed hashicorp/random v3.1.0 (signed by HashiCorp)
- Installing hashicorp/aws v3.56.0...
- Installed hashicorp/aws v3.56.0 (signed by HashiCorp)
- Installing hashicorp/local v2.1.0...
- Installed hashicorp/local v2.1.0 (signed by HashiCorp)

Terraform has created a lock file .terraform.lock.hcl to record the provider
selections it made above. Include this file in your version control repository
so that Terraform can guarantee to make the same selections by default when
you run "terraform init" in the future.

Terraform has been successfully initialized!

You may now begin working with Terraform. Try running "terraform plan" to see
any changes that are required for your infrastructure. All Terraform commands
should now work.

If you ever set or change modules or backend configuration for Terraform,
rerun this command to reinitialize your working directory. If you forget, other
commands will detect it and remind you to do so if necessary.



 $ terraform apply

Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

Plan: 4 to add, 0 to change, 0 to destroy.

....

Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

random_string.random: Creating...
random_string.random: Creation complete after 0s [id=1l2uexofx88sl516]
aws_dynamodb_table.stage_locking: Creating...
aws_s3_bucket.state_storage: Creating...
aws_s3_bucket.state_storage: Creation complete after 7s [id=terraform-state-storage-1l2uexofx88sl516]
aws_dynamodb_table.stage_locking: Creation complete after 9s [id=terraform-state-locking-1l2uexofx88sl516]
local_file.backend_config: Creating...
local_file.backend_config: Creation complete after 0s [id=73ad112baeb1af2bac294cdd93a3e56e2295df8b]

Apply complete! Resources: 4 added, 0 changed, 0 destroyed.

```

You should now see a `backend.tf` file in your local directory with our new backend config.

```
 $ ll
total 20
-rwxrwxr-x 1 thomas thomas  247 Sep  3 07:00 backend.tf*
-rw-rw-r-- 1 thomas thomas  185 Sep  2 16:32 backend.tf.tpl
-rw-rw-r-- 1 thomas thomas  932 Sep  2 16:31 state_storage.tf
-rw-rw-r-- 1 thomas thomas 6123 Sep  3 07:00 terraform.tfstate
```

Migrate the state to this backend with another `terraform init`.

```
 $ terraform init

Initializing the backend...
Do you want to copy existing state to the new backend?
  Pre-existing state was found while migrating the previous "local" backend to the
  newly configured "s3" backend. No existing state was found in the newly
  configured "s3" backend. Do you want to copy this state to the new "s3"
  backend? Enter "yes" to copy and "no" to start with an empty state.

  Enter a value: yes

Releasing state lock. This may take a few moments...

Successfully configured the backend "s3"! Terraform will automatically
use this backend unless the backend configuration changes.

Initializing provider plugins...
- Reusing previous version of hashicorp/aws from the dependency lock file
- Reusing previous version of hashicorp/local from the dependency lock file
- Reusing previous version of hashicorp/random from the dependency lock file
- Using previously-installed hashicorp/local v2.1.0
- Using previously-installed hashicorp/random v3.1.0
- Using previously-installed hashicorp/aws v3.56.0

Terraform has been successfully initialized!

You may now begin working with Terraform. Try running "terraform plan" to see
any changes that are required for your infrastructure. All Terraform commands
should now work.

If you ever set or change modules or backend configuration for Terraform,
rerun this command to reinitialize your working directory. If you forget, other
commands will detect it and remind you to do so if necessary.
```

We can check the S3 bucket to confirm our new state is in there.

```
 $ aws s3 ls s3://terraform-state-storage-vi5xvgrx75613zof
2021-09-03 07:03:27       6123 example-state-storage
```

## Wrap Up

Awesome. We have now used Terraform to create a place to store state and migrated to it.

To use this backend in other Terraform stacks simply copy the `backend.tf` into it and re-run `terraform init`.

Check out [this post](/posts/2021-08-23-cross-region-cross-account-s3-replication/) to see how to add some replication to your 
storage to make it harder to accidentally destroy.

If you're having issues with the Terraform, I have a working copy in 
[GitHub.](https://github.com/incpac/aws_terraform_samples/tree/master/state_storage)
