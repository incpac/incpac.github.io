---
layout: single
title: SSH Proxy with AWS Systems Manager
date: 2024-03-22
---

This one is more of a personal note than anything else. Recently I've had a need to connect to devices attached to a
host I don't have any sort of network access to. Thankfully these devices have AWS ~~Simple~~ Systems Manager agents
installed. I can connect to that and set up a SSH proxy to allow me to access the remote devices.

# SSH via Systems Manager

First step is to set up port forwarding via the Systems Manager agent. This will connect local port 2222 to port 22 on
the remote device.

```sh
export NODE_ID=""
aws ssm start-session --target $NODE_ID --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["22"],"localPortNumber":["2222"]}'
```

The tunnel will operate as long as this command remains running.

From here, you can use SSH to do anything you could if you had a direct connection. For example, SCP files to or from the
device.

```sh
export SSH_KEY_PATH=""
export SOURCE_PATH=""
export TARGET_PATH=""
scp -P 2222 -I $SSH_KEY_PATH -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $SOURCE_PATH username@localhost:$TARGET_PATH
```

## Note

If you've already got a record for `localhost:2222` in your known hosts file this would normally fail.

```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
Someone could be eavesdropping on you right now (man-in-the-middle attack)!
It is also possible that a host key has just been changed.
```

We get around this by setting `UserKnownHostsFile` and `StrictHostKeyChecking`. You normally wouldn't want to do this,
however in our situation we re-use the same hostname/port combo for different hosts. The alternative is to either remove
the entries in the known hosts file, or to dedicate one port per SSM host so you don't run into collisions.

# HTTP Proxy

This is really useful to connect to remote devices over HTTP. With the tunnel still open run the following.

```sh
export SSH_KEY_PATH=""
sudo ssh -p 2222 -i $SSH_KEY_PATH -ND 9999 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no username@localhost
```

Set your browser proxy config

```
Host: 127.0.0.1
Port: 9999
Protocol: SOCKS v5
```

Now just browse to any page on the remote network and your web browser will proxy the request through the SSM agent.
