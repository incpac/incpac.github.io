---
layout: single
title: Playing Around with AWS IPAM
date: 2024-04-20
---

Story time. ~~Earlier in the month~~ Last month at this point, I was laying out a VPC with some subnets in Terraform.
I didn't want to have to manually enter subnets so wanted to create them dynamically from the CIDR assigned to the VPC.
I had forgotten what the [`cidrsubnet`](https://developer.hashicorp.com/terraform/language/functions/cidrsubnet)
Terraform function was called and went Googling for it.

Rather than the Terraform docs for the function showing up as the first result I got a StackOverflow (or something
similar) post of someone asking the same thing. Instead of simply recommending the Terraform function the top response
recommended checking out [AWS's IP Address Manager.](https://docs.aws.amazon.com/vpc/latest/ipam/what-it-is-ipam.html)
IPAM is a feature of the VPC service that lets you plan, track, and monitor IP addresses across your workloads.

This looked cool so I wanted to play around with it a bit.

# Lab 01 - Intro to IPAM

Reading through the docs the first thing we're going to want to do is set up an IPAM pool and a VPC in a single account
and a single region. In this case we're going to go with ap-southeast-2 as that's my closest, but you can go where ever
you want. This is what we're going to set up.

![Lab 01](/assets/posts/playing-around-with-aws-ipam/05-lab01.png)

To start with we need some standard Terraform config.

```terraform
terraform {
  required_version = "~> 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.39"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"

  default_tags {
    tags = {
      Stack = "IPAM Lab"
    }
  }
}
```

We then create our root IPAM. Note that we need to list all regions we want to create pools in along with the region the
IPAM is created in. Currently we're only using our local region but we're going to want to do more later on.

```terraform
data "aws_region" "current" {}

resource "aws_vpc_ipam" "test" {
  description = "IPAM Test"

  "operating_regions" {
    region_name = data.aws_region.current.name
  }

  tags = {
    Name = "IPAM Test"
  }
}
```

Apply this and we can see the IPAM in the AWS console.

![Base IPAM](/assets/posts/playing-around-with-aws-ipam/01-base-ipam.png)

Next up we add an IPAM Pool and a CIDR. This is the pool of IP addresses the IPAM can dish out. We're going to name
this after the account ID which we can pull from the `aws_caller_identity` data block.

```terraform
data "aws_caller_identity" "main" {}

resource "aws_vpc_ipam_pool" "account" {
  description    = "IPAM Test - Account Pool"
  address_family = "ipv4"
  ipam_scope_id  = aws_vpc_ipam.test.private_default_scope_id

  tags = {
    Name = data.aws_caller_identity.main.account_id
  }
}

resource "aws_vpc_ipam_pool_cidr" "account" {
  ipam_pool_id = aws_vpc_ipam_pool.account.id
  cidr         = "10.0.0.0/16"
}
```

Apply this and you should now see the Private Pool

![Private Pool](/assets/posts/playing-around-with-aws-ipam/02-private-pool.png)

But you'll notice this pool isn't associated with a region. We're going to need a region pool if we want to be able to
use it to create a VPC. We'll create this as a child of the root pool.

```terraform
resource "aws_vpc_ipam_pool" "region" {
  description         = "IPAM Test - Region Pool - ${data.aws_region.current.name}"
  address_family      = "ipv4"
  ipam_scope_id       = aws_vpc_ipam_pool.account.ipam_scope_id
  locale              = data.aws_region.current.name
  source_ipam_pool_id = aws_vpc_ipam_pool.account.id

  tags = {
    Name = data.aws_region.current.name
  }
}
```

Delegate this pool a chunk IP addresses from the root pool. We're going to use a `/20`. Then we'll create a VPC using a
`/24` CIDR.

```terraform
resource "aws_vpc_ipam_pool_cidr" "region" {
  ipam_pool_id   = aws_vpc_ipam_pool.region.id
  netmask_length = 20
}

resource "aws_vpc" "vpc" {
  ipv4_ipam_pool_id   = aws_vpc_ipam_pool.region.id
  ipv4_netmask_length = 24
  depends_on          = [aws_vpc_ipam_pool_cidr.region]

  tags = { Name = data.aws_region.current.name }
}
```

With that, we've now got a pool of 4096 addresses assigned to Sydney and a VPC with 256 addresses.

![Sydney Pool](/assets/posts/playing-around-with-aws-ipam/03-address-allocation.png)

# Lab 02 - Let's go multi-region

This time around we're going to add additional regions. The example we're building will create a VPC in us-east-1 and
us-west-2.

![Lab 02](/assets/posts/playing-around-with-aws-ipam/06-lab02.png)

Rather than define every resource for each region manually we're going to create a `region` module and re-use it. First
thing to do is set up the base TF requirements. We need the provider for the main region and one for the region we're
going to deploy to.

```terraform
terraform {
  required_version = "~> 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.39"

      configuration_aliases = [aws.primary, aws.region]
    }
  }
}
```

We need to know the ID of the parent IPAM pool, and the size of the VPC we're going to create.

```terraform
variable "parent_pool_id" {
  type        = string
  description = "ID of the parent IPAM Pool"
}

variable "vpc_cidr_size" {
  type        = number
  description = "Size of the VPC CIDR block"
}
```

Pull some information from the account and existing resources.

```terraform
data "aws_region" "region" { provider = aws.region }

data "aws_vpc_ipam_pool" "parent" {
  provider = aws.primary
  ipam_pool_id = var.parent_pool_id
}
```

From here we can create the Pool and CIDR for the region. Note that these are created in the primary region where the
parent IPAM Pool resides. When you open up the IPAM console in the target region you won't be able to see the pool,
however if you go to manually create a VPC in the region you will see the regional pool as an option when selecting the
`IPAM-allocatied IPv4 CIDR block` option.

```terraform
resource "aws_vpc_ipam_pool" "region" {
  provider = aws.primary

  description         = "Region Pool - ${data.aws_region.region.name}"
  address_family      = "ipv4"
  ipam_scope_id       = data.aws_vpc_ipam_pool.parent.ipam_scope_id
  locale              = data.aws_region.region.name
  source_ipam_pool_id = data.aws_vpc_ipam_pool.parent.ipam_pool_id

  tags = { Name = data.aws_region.region.name }
}

resource "aws_vpc_ipam_pool_cidr" "region" {
  provider = aws.primary

  ipam_pool_id   = aws_vpc_ipam_pool.region.id
  netmask_length = var.vpc_cidr_size
}
```

Then we can create the VPC in the target region

```terraform
resource "aws_vpc" "vpc" {
  provider = aws.region
  ipv4_ipam_pool_id   = aws_vpc_ipam_pool.region.id
  ipv4_netmask_length = var.vpc_cidr_size
  depends_on          = [aws_vpc_ipam_pool_cidr.region]

  tags = { Name = data.aws_region.region.name }
}
```

Back in the parent terraform remove the `aws_vpc_ipam_pool.region`,
`aws_vpc_ipam_pool_cidr.region`, and `aws_vpc` resources.

We're going to add the following providers

```terraform
provider "aws" {
  region = "us-west-2"
  alias  = "region01"

  default_tags {
    tags = { Stack = "IPAM Lab" }
  }
}

provider "aws" {
  region = "us-east-1"
  alias  = "region02"

  default_tags {
    tags = { Stack = "IPAM Lab" }
  }
}

data "aws_region" "region01" { provider = aws.region01 }
data "aws_region" "region02" { provider = aws.region02 }

locals {
  operating_regions = distinct([
    data.aws_region.current.name,
    data.aws_region.region01.name,
    data.aws_region.region02.name,
  ])
}
```

What we're doing here is building a list of regions we want to create pools in along with the region we're creating the
IPAM in. We then remove any duplicates.

We do it this way so you change what region `region01` and `region02` are actually sitting in without having to make
any changes to other parts of the code. They can even be the same region as the root pool. We can then iterate over this
local and update the IPAM to operate in each region.

```terraform
resource "aws_vpc_ipam" "test" {
  description = "IPAM Test"

  dynamic "operating_regions" {
    for_each = local.operating_regions
    content {
      region_name = operating_regions.value
    }
  }

  tags = {
    Name = "IPAM Test"
  }
}
```

Then We create an instance of the `region` module for each region.

```terraform
module "region01" {
  source = "./region"

  providers = {
    aws.primary = aws,
    aws.region = aws.region01,
  }

  parent_pool_id = aws_vpc_ipam_pool.account.id
  vpc_cidr_size  = 24
}

module "region02" {
  source = "./region"

  providers = {
    aws.primary = aws,
    aws.region = aws.region02,
  }

  parent_pool_id = aws_vpc_ipam_pool.account.id
  vpc_cidr_size  = 24
}
```

Give this an apply and you should then be able to see a couple of regional pools.

![Regional Pools](/assets/posts/playing-around-with-aws-ipam/04-regional-pools.png)

Note that in this example, the VPC is the same size as the regional pool, taking up the entire allocation.

![Regional Pool](/assets/posts/playing-around-with-aws-ipam/07-regional-pool.png)

# Lab 03 - Baking it into the AWS Org

The next move would be to enable IPAM for the entire AWS Organization (assuming you're using one). In our example
we'll have a central Shared Services account, and two Test accounts. We will delegate the IPAM for the organization
to the Shared Services accounts.

To do this first you're going to want to create these three accounts. Then to delegate access log into your root
account, browse to AWS Organizations > Services. Look for Amazon VPC IP Address Manager. Click on "Enable trusted
access"

![Enable Trusted Access](/assets/posts/playing-around-with-aws-ipam/08-enable-trusted-access.png)

Follow this with selecting "Show the option to enable trusted access" and entering "enabled" when asked. Next,
go the IPAM console, Planning, and Organization Settings. Click on Delegate. Enter the account ID for your
Shared Services account and click on Save Changes.

![Delegate IPAM Admin](/assets/posts/playing-around-with-aws-ipam/09-delegate-ipam-administrator.png)

Switch to the Shared Services account and you'll see this.

![Delegated IPAM Admin](/assets/posts/playing-around-with-aws-ipam/10-delegated-ipam-administrator.png)

Awesome. So same as the first two labs, we need to set up some Terraform.

```terraform
terraform {
  required_version = "~> 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.39"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"
  default_tags {
    tags = { Stack = "IPAM Lab" }
  }
}

```

We're going to set up three spokes. Two in account one across two different regions, and one in account two.

```terraform
locals {
  account_id_1 = "690402899467"
  account_id_2 = "851725293593"
}

provider "aws" {
  region = "ap-southeast-2"
  alias  = "spoke01"

  assume_role {
    role_arn = "arn:aws:iam::${local.account_id_1}:role/SharedServices-AdministratorAccess"
  }

  default_tags {
    tags = { Stack = "IPAM Lab" }
  }
}

provider "aws" {
  region = "ap-southeast-2"
  alias  = "spoke02"

  assume_role {
    role_arn = "arn:aws:iam::${local.account_id_2}:role/SharedServices-AdministratorAccess"
  }

  default_tags {
    tags = { Stack = "IPAM Lab" }
  }
}

provider "aws" {
  region = "us-west-2"
  alias  = "spoke03"

  assume_role {
    role_arn = "arn:aws:iam::${local.account_id_1}:role/SharedServices-AdministratorAccess"
  }

  default_tags {
    tags = { Stack = "IPAM Lab" }
  }
}
```

But before we get to that we need to configure the Organization level settings. This involves creating the IPAM and the
shared pool, creating the Resource Access Manager share and sharing it to the Organization, and creating the root CDIR
block.

```terraform
variable "total_pool_cidr" {
  type        = string
  description = "CIDR range for the entire pool"
  default     = "10.0.0.0/8"
}

resource "aws_vpc_ipam" "main" {
  description = "IPAM Lab"

  dynamic "operating_regions" {
    for_each = local.operating_regions
    content { region_name = operating_regions.value }
  }

  tags = { Name = "IPAM Lab" }
}

resource "aws_vpc_ipam_pool" "shared" {
  description = "Org Pool"

  address_family = "ipv4"
  ipam_scope_id  = aws_vpc_ipam.main.private_default_scope_id
}

resource "aws_ram_resource_share" "ipam_pool" {
  name                      = "IPAM Lab"
  allow_external_principals = false
  permission_arns           = [
    "arn:aws:ram::aws:permission/AWSRAMDefaultPermissionsIpamPool"
  ]
}

resource "aws_ram_resource_association" "ipam_pool" {
  resource_arn       = aws_vpc_ipam_pool.shared.arn
  resource_share_arn = aws_ram_resource_share.ipam_pool.arn
}

data "aws_organizations_organization" "org" {}

resource "aws_ram_principal_association" "org" {
  principal          = data.aws_organizations_organization.org.arn
  resource_share_arn = aws_ram_resource_share.ipam_pool.arn
}

resource "aws_vpc_ipam_pool_cidr" "shared" {
  ipam_pool_id = aws_vpc_ipam_pool.shared.id
  cidr         = var.total_pool_cidr
}
```

The next step is to create a Pool per region. We do this by creating a list of regions for each spoke, then removing
all duplicates. From there we can iterate over the list. But first we need our Region module. In a directory named
`region` create the following.

```terraform
terraform {
  required_version = "~> 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.39"
    }
  }
}

data "aws_region" "curent" {}

variable "parent_pool_id" {
  description = "ID of the parent address pool"
  type        = string
}

variable "netmask_length" {
  description = "Length of the Netmask to allocate to this region"
  type        = number
}

variable "region" {
  description = "Region to create the address pool for"
  type        = string
}

data "aws_vpc_ipam_pool" "parent" {
  ipam_pool_id = var.parent_pool_id
}

data "aws_region" "deploy" {}

resource "aws_vpc_ipam_pool" "deploy" {
  description         = "Region Pool - ${var.region}"
  address_family      = "ipv4"
  ipam_scope_id       = data.aws_vpc_ipam_pool.parent.ipam_scope_id
  locale              = var.region
  source_ipam_pool_id = data.aws_vpc_ipam_pool.parent.ipam_pool_id
}

resource "aws_vpc_ipam_pool_cidr" "deploy" {
  ipam_pool_id   = aws_vpc_ipam_pool.deploy.id
  netmask_length = var.netmask_length
}

output "ipam_pool_id" {
  description = "ID of the VPC IPAM pool"
  value = aws_vpc_ipam_pool.deploy.id
}
```

What we're doing here is taking a Parent IPAM pool and a CIDR length and creating a child IPAM pool for the region.

We call this with the following:

```terraform
data "aws_region" "main" {}
data "aws_region" "spoke01" { provider = aws.spoke01 }
data "aws_region" "spoke02" { provider = aws.spoke02 }
data "aws_region" "spoke03" { provider = aws.spoke03 }

locals {
  operating_regions = distinct([
    data.aws_region.main.name,
    data.aws_region.spoke01.name,
    data.aws_region.spoke02.name,
    data.aws_region.spoke03.name,
  ])
}

module "regions" {
  for_each = toset(local.operating_regions)

  source = "./region"

  parent_pool_id = aws_vpc_ipam_pool.shared.id
  region         = each.value
  netmask_length = 13
}

locals {
  regional_pools = {
    for k, v in module.regions : k => v.ipam_pool_id
  }
}
```

As described earlier, what we're doing here is creating an `aws_region` data block for each region. We then use these to
create a list of each region name, removing the duplicates using the `distinct()` Terraform function. A Region module
instance is then created for each region in the list. We then create a `regional_pools` map linking the name of the
region to the IPAM Pool ID for later reference.

~~Now that we've got a pool for each region we're operating in, we need to create a child pool for each account
operating in each region. First create an `account` module.~~

**Update:** There used to be a third tier pool here for the account/region combo. It didn't work and I ripped it out
while troubleshooting and didn't keep the code (I should probably keep all this stuff in git). Instead we're placing
the VPC directly in the region pool.

```terraform
terraform {
  required_version = "~> 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.39"
    }
  }
}

variable "vpc_netmask_length" {
  type        = number
  description = "Netmask length for the default VPC"
  default     = 24
}

variable "regional_pools" {
  type = map(string)
  description = "Dict of IPAM pool IDs for each reagion"
}

data "aws_caller_identity" "deploy" {}
data "aws_region" "deploy" {}

resource "aws_vpc" "vpc" {
  ipv4_ipam_pool_id = var.regional_pools[data.aws_region.deploy.name]
  ipv4_netmask_length = var.vpc_netmask_length

  tags = {
    Name = "${data.aws_caller_identity.deploy.account_id}/${data.aws_region.deploy.name}"
  }
}
```

Then back in the root we want one instance of this module per spoke provider.

```terraform
module "spoke01" {
  depends_on = [aws_ram_principal_association.org]

  source = "./account"

  providers = {
    aws = aws.spoke01
  }

  regional_pools = local.regional_pools
}

module "spoke02" {
  depends_on = [aws_ram_principal_association.org]

  source = "./account"

  providers = {
    aws = aws.spoke02
  }

  regional_pools = local.regional_pools
}

module "spoke03" {
  depends_on = [aws_ram_principal_association.org]

  source = "./account"

  providers = {
    aws = aws.spoke03
  }

  regional_pools = local.regional_pools
}
```

With this we should be good to apply. It will set up the root IPAM Pool, a sub-pool for each region, then a VPC.

## And cue the dramatic entrance of chaos and calamity, right on schedule

```
│ Error: creating EC2 VPC: operation error EC2: CreateVpc, https response error StatusCode: 400, RequestID:
│ 4ca0edc8-06b2-40a3-9297-cf1a80a897a4, api error InvalidIpamPoolId.NotFound: The ipam-pool ID
│ 'ipam-pool-0aaf0f8e9e9010072' does not exist
```

So what I was trying to do here wasn't going to work. I had thought sharing the root IPAM Pool at the Organization
level would make it available to all accounts. Technically it does, but child pools are considered their own resource.
You would need to share each one out to the Organization.

My original thought was to create a pool per region, then split that up. That way if something went wrong you could
instantly tell where in the world the problem was based on the IP address. Probably a hang up from when I was managing
servers across multiple datacenters where finding them was easier going Region->Environment vs Environment->Region.

Though technically we could continue on this way. You would just need to create a RAM share for each regional pool. But
that sounds like a pain in the ass. You could go the other way, create pool per environment then create regional pools
inside it, but then you end up with the same problem of needing to create a share per environment.

No, I think I'm just going to skip the two tiered approach here and create a pool per environment/region.

# Lab 04 - Simplifying things a bit

We're going to build off of Lab 03 (no point letting all that go to waste)

Trash the account and regional stuff. You should be down to just the root IPAM pool and the RAM share.

## Side tangent

I used to be against mono-repos. I like having things split up as required. However a couple of recent projects have me
reconsidering that. Having to coordinate changes across three or more stacks has started to get difficult.

Having said that, I think I might still split this one one. The Org level IPAM is shared out to all accounts in the
AWS Organization. You don't have to update the share each time you add a new account. This would be my main concern
against splitting it up and it doesn't apply here.

But if we do split it up, then each account/region becomes their own environment. The only thing that we need to pass in
is the root IPAM ID and that isn't likely to ever change.

Yeah, I think I like that. However, I'm going to take it in as a variable rather than read it from a remote state.

## Back to it

OK, so we've got more to rip out. Get rid of the providers for the spokes. Add a variable for a list of regions to
operate in. We're then going to create a `local` that takes this list, adds the current region to it, and removes any
duplicates.

```terraform
variable "operating_regions" {
  description = "List of regions to create the Pool for"
  type        = list(string)
  default     = ["ap-southeast-2", "us-west-2"]
}

data "aws_region" "current" {}

locals {
  operating_regions = distinct(concat([data.aws_region.current.name], var.operating_regions))
}
```

Add an output to the stack for the IPAM ID.

```terraform
output "ipam_id" {
  description = "ID of the VPC IPAM"
  value       = aws_vpc_ipam.main.id
}
```

With that done you should be good to apply. The IPAM ID will be spit out at the end. We're going to need this later.

In another directory we're going to start from scratch for a spoke.

```terraform
terraform {
  required_version = "~> 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.39"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"

  default_tags {
    tags = { Stack = "IPAM Lab" }
  }
}

variable "region" {
  description = "ID of the AWS region to deploy to"
  type        = string
}

variable "iam_role" {
  description = "ARN of the IAM role in the target account to assume"
  type        = string
}

provider "aws" {
  alias  = "deploy"
  region = var.region

  assume_role {
    role_arn = var.iam_role
  }

  default_tags {
    tags = {
      Stack = "IPAM Lab"
    }
  }
}
```

Next up we want to create the IPAM pool

```terraform
variable "parent_pool_id" {
  description = "ID of the parent IPAM pool"
  type        = string
}

variable "netmask_length" {
  description = "Length of the Netmask to allocate to this spoke"
  type        = number
}

variable "name" {
  description = "Name of the spoke"
  type        = string
  default     = null
}

data "aws_caller_identity" "deploy" {
  provider = aws.deploy
}

data "aws_vpc_ipam_pool" "parent" {
  ipam_pool_id = var.parent_pool_id
}

locals {
  pool_name = "${data.aws_caller_identity.deploy.account_id}/${var.region}"
}

resource "aws_vpc_ipam_pool" "pool" {
  description         = "Spoke Pool - ${local.pool_name}"
  address_family      = "ipv4"
  ipam_scope_id       = data.aws_vpc_ipam_pool.parent.ipam_scope_id
  locale              = var.region
  source_ipam_pool_id = data.aws_vpc_ipam_pool.parent.ipam_pool_id
}
```

We give that an apply to see how we're going and ... damn. Another road block.

```
│ Error: creating IPAM Pool: UnauthorizedOperation: You are not authorized to perform this operation. User:
│ arn:aws:sts::690402899467:assumed-role/SharedServices-AdministratorAccess/aws-go-sdk-1714091794708223000 is not
│ authorized to perform: ec2:CreateIpamPool on resource: arn:aws:ec2::381492113005:ipam-pool/ipam-pool-053687ec45ef90dfc
│ because no resource-based policy allows the ec2:CreateIpamPool action.
```

A quick check of the policy on the RAM share and indeed, remote account cannot create sub-pools. Bugger.

At this point I'm already a bit annoyed we have to tell IPAM which regions we may possible want to operate in in
advance, I really don't want to have to deal with sharing the sub-pools.

What if we don't share the root IPAM pool, but create a single sub-pool that uses the entirety of the root and share
that?

...

And it occurs to me that a pool needs to be tied to a region for us to be able to make any real use of it. Which
may explain why I can't do a lot with the root pool share in the other accounts/regions. This is what I get for taking
so long to write this post.

It's at this point it occurs to me that we can use a single RAM share and include all regional Pools in it. We don't
have to create a share for each pool.

Okay back to the root stack we create a pool per region.

```terraform
resource "aws_vpc_ipam_pool" "shared" {
  for_each = toset(local.operating_regions)

  description = "Shared Pool - ${each.value}"

  address_family      = "ipv4"
  ipam_scope_id       = aws_vpc_ipam_pool.org.ipam_scope_id
  source_ipam_pool_id = aws_vpc_ipam_pool.org.id
  locale              = each.value
}
```

Update the RAM share for these.

```terraform
resource "aws_ram_resource_association" "ipam_pool" {
  for_each = aws_vpc_ipam_pool.shared

  resource_arn       = each.value.arn
  resource_share_arn = aws_ram_resource_share.ipam_pool.arn
}
```

Now we need to rethink subnetting. We have to split up the Org subnet into each region, but we may also want to include
additional regions at a later date. I'm thinking we go for a `/12`. This gives us 16 regions or private scopes. If we
want to create `/16` VPCs, we can get 16 of them per region.

Back in the org stack

```terraform
resource "aws_vpc_ipam_pool_cidr" "shared" {
  for_each = toset(local.operating_regions)

  ipam_pool_id = aws_vpc_ipam_pool.shared[each.value].id
  cidr         = cidrsubnet(aws_vpc_ipam_pool_cidr.org.cidr, 4, index(local.operating_regions, each.value))
}
```

Apply that and you should be able to see our two regional pools

![Regional Pools](/assets/posts/playing-around-with-aws-ipam/11-regional-pools.png)

I've also over complicated the spokes. Let's rip all that out and start again.

```terraform
terraform {
  required_version = "~> 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.39"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"

  default_tags {
    tags = { Stack = "IPAM Lab" }
  }
}

variable "netmask_length" {
  description = "Length of the Netmask to allocate to this spoke"
  type        = number
}
```

We can retrieve the IPAM Pool using the name. This way we don't have to go looking for the right pool for the region
we're deploying into.

```terraform
data "aws_region" "current" {}

data "aws_vpc_ipam_pool" "pool" {
  filter {
    name   = "description"
    values = ["Shared Pool - ${data.aws_region.current.name}"]
  }
}
```

We can then create a VPC and some subnets

```terraform
resource "aws_vpc" "vpc" {
  ipv4_ipam_pool_id   = data.aws_vpc_ipam_pool.pool.id
  ipv4_netmask_length = 20
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  count = length(data.aws_availability_zones.available.names)

  vpc_id            = aws_vpc.vpc.id
  availability_zone = data.aws_availability_zones.available.names[count.index]
  cidr_block        = cidrsubnet(aws_vpc.vpc.cidr_block, length(data.aws_availability_zones.available.names), count.index)

  tags = {
    Name = "Shared Pool - ${data.aws_availability_zones.available.names[count.index]}"
  }
}

resource "aws_internet_gateway" "gateway" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_default_route_table" "table" {
  default_route_table_id = aws_vpc.vpc.default_route_table_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gateway.id
  }
}
```

Spin this up and you should be able to see the allocation in the IPAM console.

![IPAM Allocation](/assets/posts/playing-around-with-aws-ipam/12-ipam-allocation.png)

Switch over to the VPC console in `us-west-2` and you should be able to see our subnets.

![VPC Subnets](/assets/posts/playing-around-with-aws-ipam/13-vpc-subnets.png)

# Closing thoughts

In the end I quite like AWS IPAM. Not sure I'm ever going to have a need for it though. I personally haven't come across
an AWS network large enough. And while it you could also use it to manage your on-premise network too, that seems like
something that'd be easier to include from the start. But who knows, someone may decide it's worth importing their
existing environment into it.

Not sure how I feel about the requirements for a pool to be dedicated to a single region. However it does provide that
Region->Environment link I was looking for.

Actually thinking about it, my current project may have been able to make use of it. But I feel it's probably not going
to be worth retroactively implementing. Oh well

![Next time baby](/assets/posts/playing-around-with-aws-ipam/14-next-time-baby.gif)

If you have any difficulty following along with any of this I've stashed everything on
[GitHub.](https://github.com/incpac/aws-ipam-lab)
