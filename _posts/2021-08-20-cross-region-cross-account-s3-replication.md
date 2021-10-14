---
layout: single
title: Cross-Region, Cross-Account S3 Replication in Terraform
date: 2021-08-23
---


We're getting ready to live with a project I'm currently working on. This has led to the last few weeks being full on. Most of 
it relating to a lot of data replication. 

One of the tasks assigned to me was to replicate an S3 bucket cross region into our backups account. Normally this wouldn't be 
an issue but between the cross-account-ness, cross-region-ness, and customer managed KMS keys, this task kicked my ass. So I 
thought I'd write it up.


## Provider Conf

First thing to get set up is our provider configuration. We're going to deploy into our source account and use a cross-account 
role to deploy into the second. You're going to want to set that role up now if you don't have it. I'm not going to detail how 
to here, but you can check out the 
[AWS documentation](https://docs.aws.amazon.com/IAM/latest/UserGuide/tutorial_cross-account-with-roles.html) if it's not 
something you've done before.

```terraform
provider "aws" {
  region = "ap-southeast-2"
}

provider "aws" {
  alias  = "destination"
  region = "us-west-2"

  assume_role {
    role_arn = "arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME"
  }
}
```

You'll need to swap out the `role_arn` for that of the role you've just created.

We also need some details about the accounts we're deploying to:

```terraform
data "aws_caller_identity" "source" {}

data "aws_caller_identity" "destination" {
  provider = aws.destination
}
```

## KMS Keys

Next up we want a couple of KMS keys. One in each account.

```terraform 
resource "aws_kms_key" "source" {
  deletion_window_in_days = 30
  enable_key_rotation     = true
}
```

Our destination one is a bit special because we need a policy that allows the source account to access it.

```terraform 
resource "aws_kms_key" "destination" {
  provider = aws.destination

  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.destination_kms_key.json
}

data "aws_iam_policy_document" "destination_kms_key" {
  statement {
    principals {
      type = "AWS"
      identifiers = [
        data.aws_caller_identity.source.account_id
      ]
    }

    actions = [
      "kms:Encrypt"
    ]

    resources = ["*"]
  }

  statement {
    principals {
      type = "AWS"
      identifiers = [
        data.aws_caller_identity.destination.account_id
      ]
    }

    actions = [
      "kms:*"
    ]

    resources = ["*"]
  }
}
```

## S3 Buckets

Create the S3 buckets using our shiny new keys.

```terraform 
resource "aws_s3_bucket" "source" {
  bucket = "replication-test-source-${random_string.random.result}"
  acl    = "private"

  versioning {
    enabled = true
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = aws_kms_key.source.arn
        sse_algorithm     = "aws:kms"
      }
    }
  }
}

resource "aws_s3_bucket" "destination" {
  provider = aws.destination

  bucket = "replication-test-destination-${random_string.random.result}"
  acl    = "private"

  versioning {
    enabled = true
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = aws_kms_key.destination.arn
        sse_algorithm     = "aws:kms"
      }
    }
  }
}
```

## IAM Role

We're gonna need an IAM role in our source account that S3 can use to access the destination bucket. This role'll need access 
to read from the source bucket, write to the destination bucket, and encypt and decrypt with the KMS keys.

```terraform 
resource "aws_iam_role" "replication" {
  name               = "replication-test-${random_string.random.result}"
  assume_role_policy = data.aws_iam_policy_document.replication_role.json
}

resource "aws_iam_role_policy" "replication" {
  name   = "replication"
  role   = aws_iam_role.replication.id
  policy = data.aws_iam_policy_document.replication_policy.json
}

data "aws_iam_policy_document" "replication_role" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

data "aws_iam_policy_document" "replication_policy" {
  statement {
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket"
    ]

    resources = [
      aws_s3_bucket.source.arn
    ]
  }

  statement {
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging"
    ]

    resources = [
      "${aws_s3_bucket.source.arn}/*"
    ]
  }

  statement {
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags"
    ]

    resources = [
      "${aws_s3_bucket.destination.arn}/*"
    ]
  }

  statement {
    actions = [
      "kms:Decrypt"
    ]

    resources = [
      aws_kms_key.source.arn
    ]
  }

  statement {
    actions = [
      "kms:Encrypt"
    ]

    resources = [
      aws_kms_key.destination.arn
    ]
  }
}
```

## Destination Bucket Policy

Now we need to allow our new IAM role to replicate into our destination bucket.

```terraform
resource "aws_s3_bucket_policy" "destination" {
  provider = aws.destination

  bucket = aws_s3_bucket.destination.id
  policy = data.aws_iam_policy_document.destination_bucket_policy.json
}

data "aws_iam_policy_document" "destination_bucket_policy" {
  statement {
    principals {
      type = "AWS"
      identifiers = [
        aws_iam_role.replication.arn
      ]
    }

    actions = [
      "s3:ReplicateDelete",
      "s3:ReplicateObject"
    ]

    resources = [
      "${aws_s3_bucket.destination.arn}/*"
    ]
  }

  statement {
    principals {
      type = "AWS"
      identifiers = [
        aws_iam_role.replication.arn
      ]
    }

    actions = [
      "s3:List*",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning"
    ]

    resources = [
      aws_s3_bucket.destination.arn
    ]
  }
}
```

## Replicate From The Source Bucket

Finally we can configure our source bucket to replicate. Add the following to the `aws_s3_bucket.source` resource.

```terraform 
server_side_encryption_configuration {
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.source.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

replication_configuration {
  role = aws_iam_role.replication.arn

  rules {
    id     = "replicate"
    status = "Enabled"

    source_selection_criteria {
      sse_kms_encrypted_objects {
        enabled = true
      }
    }

    destination {
      account_id         = data.aws_caller_identity.destination.account_id
      bucket             = aws_s3_bucket.destination.arn
      storage_class      = "STANDARD_IA"
      replica_kms_key_id = aws_kms_key.destination.arn
    }
  }
}
```

## Deploy and Test

With that you should be good to `terraform apply`. You can test by placing a new file in the bucket and seeing if it replicates.

If it doesn't show up in the destination bucket quickly, you can check file in the console. Open up a file, on the right-hand 
side you should see Replication Status. This'll tell you where it's at.

If you're having issues with the Terraform, I have a working copy in 
[GitHub.](https://github.com/incpac/aws_terraform_samples/tree/master/s3_replication_cross_account)
