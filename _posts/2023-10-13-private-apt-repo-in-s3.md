---
layout: single
title: Running a Private Apt Repository in S3 
date: 2023-10-13
---

Recently I was asked to assist with developing a software distribution system for a bunch of remote, IoT style devices
that connect directly to a VPC and have no real internet access. 

There was a mixture of in-house stuff written in Python, Bash, and Golang that would either be written directly 
to files on the device, or binaries copied from from S3 and placed where needed. There were also externally sourced
packages that needed to be installed. Mostly in Deb format. These were also housed in S3. Installation and configuration 
would then be controlled using Ansible.

Different pieces of software were managed by different teams. As you can imagine, this meant keeping track of what's 
getting installed where, and keeping versioning and dependency management straight started to become difficult.

To help clean all this up and ensure a uniform method of distributing and installing software it was decided that we 
would package everything up into Deb packages and create our own Apt repository.

This provided the benefet of having multiple versions of software available to us. Each package listed its own 
dependencies and Aptitude will handle finding and installing them for us. The team managing the IoT devices didn't 
need to know what runtime would be required for a certain piece of software or what would be required to get it working;
all of that was the responsibility of the package maintainer. 

When it came to actually creating the repo, we wanted to run this out of S3. There are a few tools to help us build a 
repository, but most of them wanted to create the entire respository locally, then sync it up with your target bucket.
Since we were building and releasing packages individually, we wanted to avoid this. The best tool for our usecase we 
found was [deb-s3.](https://github.com/deb-s3/deb-s3) This would let us create the repository and manage packages 
on a per-package basis.

Now that we've got the bones of a repository, we need to ensure we can access it from the IoT devices. The quickest way 
would be to enable a static website on the S3 bucket. The problem with this is that it opens the repo up to the world.
We wouldn't be able to control who can access it. Additionally, since our IoT devices didn't have internet access, they 
wouldn't be able to access it themselves. What we needed was some way to make Apt talk S3 via a VPC Endpoint.

Thankfully we also didn't have to create this from scratch either. The 
[apt-transport-s3](https://github.com/MayaraCloud/apt-transport-s3) Apt method provided much of the functionality we 
were looking for. We took that, replaced the credentials part with something that was compatible with our IoT devices,
and deployed it via Ansible.

With all that sorted we now had a uniform way we could release software and updates to our IoT devices and anything 
else we desired.


# Building 

Here I'm going to go over a quick demo of how to set something like this up. I'm not going to set up a network that's 
an exact copy of ours. This one will have internet access and allow the EC2 to have access to the standard S3 Endpoint.

__Set up the repository__  
1. Set up the Terraform environment located in [this repository](https://github.com/incpac/s3-apt-repo-demo): 
   `terraform apply -var="ssh_key=name-of-my-ssh-key-uploaded-to-ec2"`
1. Use SCP to copy the test HelloWorld package to the EC2 instance
1. Connect to the EC2 instance and run the following to build our test package: `bash helloworld/build.sh`. Note that you need 
   to be in the parent directory of the package.
1. You can use `dpkg` to install this package to test. Run it with `helloworld`. Don't forget to remove it afterwards
1. Install Ruby: `sudo apt install -y ruby`
1. Install [deb-s3](https://github.com/deb-s3/deb-s3): `sudo gem install deb-s3`
1. Publish the package to S3: 
   ```
   deb-s3 upload \
     --bucket apt-repo-test-blah-blah-blah \
     --s3-region my-aws-region \
     --visibility private \
     --preserve-versions \
     helloworld_0.1_all.deb 
   ```

__Configure Apt to pull from the repo__  
_This one doesn't need to be on the same instance as the first task_

1. Install [apt-transport-s3](https://github.com/MayaraCloud/apt-transport-s3) 
1. Add the following to your `/etc/apt/sources.list`
   ```
   deb [trusted=yes] s3://apt-repo-test-blah-blah-blah/ stable main 
   ```
1. Create `/etc/apt/s3auth.conf` with 
   ```
   Region = 'ap-southeast-2'
   ```
1. Test  
   ```bash
   sudo apt update
   sudo apt install helloworld
   helloworld
   ```

# Follow Up

This builds a basic setup with a single EC2 instance pointing to a bucket. Some things you probably want to do afterwards 
include configuring `apt-transport-s3` to use a VPC Endpoint and setting up signing for the Deb packages


# Known Issues 

Version v2.1.0 of the apt-transport-s3 package didn't work out the door. I received the following error when running 
`apt update`

```
Traceback (most recent call last):
  File "/usr/lib/apt/methods/s3", line 639, in <module>
    method = S3_method(config)
  File "/usr/lib/apt/methods/s3", line 426, in __init__
    self.iam.get_credentials()
  File "/usr/lib/apt/methods/s3", line 234, in get_credentials
    str(self.iamrole, 'utf-8')))
TypeError: decoding str is not supported
```

This was resolved by updating line 234 from `str(self.iamrole, 'utf-8')))` to `self.iamrole))`
