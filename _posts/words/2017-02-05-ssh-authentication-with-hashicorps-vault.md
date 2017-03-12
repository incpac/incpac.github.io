---
layout: post
title: ssh_auth_with_hashicorps_vault
category: words
permalink: /words/ssh-authentication-with-hashicorps-vault.html
author: thomas claridge
date: 2017/02/05
---


Okay, I'll admit; I am shit at updating this site... blog... thing... Whatever, today we're going to build something cool; centralized SSH authentication using Hashicorp's [Vault](https://www.vaultproject.io). We're going to stand up a Vault server and use it to generate One-Time-Passwords for SSHing (totaly a word) onto other servers.

## Why?

That's actually [a good question](http://gunshowcomic.com/513). Honestly, PAM just seems like a shitfest to set up and maintain.  

All right, I might be biased towards Hashicorp products. Having not actually managed a PAM enviroment before I could be wrong about its ease of management. It does give you to benifit of unique users logging onto servers helping auditability. But, if you're already using Vault to manage other secrets, why not use it for SSH access management as well? It gives you one-time-passwords so you won't have to worry about reuse. Even if you're not using it for authenticating your users, it could be useful for providing credentials during the provisioning of new servers.

## Standing up the Environment

This part's pretty easy. We're going to use [Vagrant](https://www.vagrantup.com/) to create two virtual machines. One to act as our Vault server and other for testing authentication. First, copy the following into a file named `Vagrantfile`.

```
Vagrant.configure '2' do |config|

  config.vm.box = 'ubuntu/xenial64'

  config.vm.define 'vault' do |vault|

    vault.vm.network 'private_network', ip: '172.23.1.11'
  end


  config.vm.define 'test' do |test|

    test.vm.network 'private_network', ip: '172.23.1.12'
  end
end
```

Then run `vagrant up`. This can take a while as it creates our new VM's. To connect to either server, use one of the following:

```
$ vagrant ssh vault
$ vagrant ssh test
```


##  Set up Vault

Next we're going to have to set up our Vault server. Installing Vault is really simple; you pretty much just download and run. This entire step is run on our "vault" server.

```
$ sudo apt-get install -y unzip sshpass
$ curl https://releases.hashicorp.com/vault/0.6.4/vault_0.6.4_linux_amd64.zip > vault.zip
$ unzip vault.zip
$ sudo cp vault /usr/local/bin
```

Now just run `vault` to confirm it's on your PATH.

```
$ vault                                                           
usage: vault [-version] [-help] <command> [args]                                        
...                             
```

With Vault installed the next step is to start a Vault server. We're going to run the server in "dev" mode. It's not secure, but it means we won't have to screw around with the Sealing/Unsealing process. To read more on that check the official documentation [here.](https://www.vaultproject.io/intro/getting-started/deploy.html) 

```
$ vault server -dev -dev-listen-address="0.0.0.0:8200"
==> Vault server configuration:

                 Backend: inmem
                     Cgo: disabled
              Listener 1: tcp (addr: "0.0.0.0:8200", cluster address: "", tls: "disabled")
               Log Level: info
                   Mlock: supported: true, enabled: false
                 Version: Vault v0.6.4
             Version Sha: f4adc7fa960ed8e828f94bc6785bcdbae8d1b263

==> WARNING: Dev mode is enabled!

In this mode, Vault is completely in-memory and unsealed.
Vault is configured to only have a single unseal key. The root
token has already been authenticated with the CLI, so you can
immediately begin using the Vault CLI.

The only step you need to take is to set the following
environment variables:

    export VAULT_ADDR='http://0.0.0.0:8200'

The unseal key and root token are reproduced below in case you
want to seal/unseal the Vault or play with authentication.
```

You're going to want to run the part where it says to export the environment variable. By default Vault is expecting to be able to connect via HTTPS but the dev server doesn't have SSL so it won't connect.

```
$ export VAULT_ADDR='http://127.0.0.1:8200'
$ vault status
Sealed: false
Key Shares: 1
Key Threshold: 1
Unseal Progress: 0
Version: 0.6.4
Cluster Name: vault-cluster-c75b1c92
Cluster ID: 0b68057c-c620-5c5d-aff1-9a8a4e1321ba
```


## Setting up the SSH Backend

Awesome. So now we've got our Vault server running, we can set it up to use the SSH backend. First we're going to have to mount this on "vault".

```
$ vault mount ssh
```

Create a new role with the `key_type` set to `otp`. This tells the backend to use One-Time-Passwords everytime a client wants to SSH onto a server. In this case our username is going to be `localadmin` and the machines authenticating on the `172.23.1.0/24` range.

```
$ vault write ssh/roles/otp_key_role key_type=otp default_user=localadmin cidr_list=172.23.1.0/24
```


## Install the Agent on the Test Server 

Jump onto the test server and install the agent.

```
$ sudo apt-get install -y unzip
$ curl https://releases.hashicorp.com/vault-ssh-helper/0.1.2/vault-ssh-helper_0.1.2_linux_amd64.zip > vault_agent.zip
$ unzip vault_agent.zip
$ sudo mv vault-ssh-helper /usr/local/bin 
```

Create the config file `/etc/vault-ssh-helper.d/config.hcl`

```
vault_addr = "http://172.23.1.11:8200"
tls_skip_verify = true
ssh_mount_point = "ssh"
allowed_roles = "*"
```

Modify the `/etc/pam.d/sshd` file as per below. Note that you're commenting out `@include common-auth` if it already exists.

```
##@include common-auth
auth requisite pam_exec.so quiet expose_authtok log=/tmp/vaultssh.log /usr/local/bin/vault-ssh-helper -config=/etc/vault-ssh-helper.d/config.hcl -dev
auth optional pam_unix.so not_set_pass use_first_pass nodelay
```

Modify the `/etc/ssh/sshd_config` with the following

```
ChallengeResponseAuthentication yes
UsePAM yes
PasswordAuthentication no
```

Check the config 

```
$ sudo vault-ssh-helper -verify-only -config=/etc/vault-ssh-helper.d/config.hcl -dev
2017/02/04 11:04:48 ==> WARNING: Dev mode is enabled!
2017/02/04 11:04:48 [INFO] using SSH mount point: ssh
2017/02/04 11:04:48 [INFO] vault-ssh-helper verification successful!
```

Create the user 

```
sudo adduser localadmin
```

## Test 

We're now ready to test. Back on the "vault" server run 

```
$ vault ssh -role otp_key_role localadmin@172.23.1.12
Welcome to Ubuntu 16.04.1 LTS (GNU/Linux 4.4.0-38-generic x86_64)

 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/advantage

  Get cloud support with Ubuntu Advantage Cloud Guest:
    http://www.ubuntu.com/business/services/cloud

118 packages can be updated.
48 updates are security updates.


*** System restart required ***
Last login: Sat Feb  4 11:16:44 2017 from 172.23.1.11
localadmin@ubuntu-xenial:~$ 
```

If you get `Failed to establish SSH connection: "exit status 6"` it means that you don't yet trust the test server. Just SSH onto it normally and it will save this to the list on known hosts.

```
$ ssh localadmin@172.23.1.12
ECDSA key fingerprint is SHA256:9rwKBR6UpLOFmX+Et49hFVpNRyhP4i2jJfw/CC70lTw.
Are you sure you want to continue connecting (yes/no)? yes
Warning: Permanently added '172.23.1.12' (ECDSA) to the list of known hosts.
```

## Conclusion
Awesome. So now we can use Vault to generate credentials for logging onto servers. Next up you'd want to stand this up as a production Vault cluster and lock down who can access the "ssh" mount point. That is definitely not going to be covered here.

Further Reading:

+ [Deploy Vault](https://www.vaultproject.io/intro/getting-started/deploy.html)
+ [Vault SSH Documentation](https://www.vaultproject.io/docs/secrets/ssh/index.html)
+ [Vault SSH Helper](https://github.com/hashicorp/vault-ssh-helper)
