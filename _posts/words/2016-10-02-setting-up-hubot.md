---
layout: post
title: Setting up Hubot
category: words
permalink: /words/setting-up-hubot.html
---

So this is something I've wanted to do for a while now and I've finally gotten around to it. I have [Github's Hubot](https://hubot.github.com/) running on a dedicated Ubuntu 16.04 VM using [Slack](https://slack.com/) as it's user interface.

### Create API Key
The Hubot interface needs access to the Slack API. This is granted through a bot API token.

1. Log into Slack via the web portal and browse to [new bot page](https://my.slack.com/services/new/bot).
2. Enter a username for your bot and click 'Add bot integration'
3. Copy the API tocken for later use.


### Install Prerequisites
Hubot runs on coffeescript (javascript). It also needs a Redis database for persistance.

```
curl -sL https://deb.nodesource.com/setup_6.x | sudo -E bash -
sudo apt-get install -y build-essential nodejs tcl redis-server
```


### Create Your Hubot
First we need a user to run the Hubot instance

```
sudo useradd --home /opt/hubot hubot
```

Next we install the Hubot generator

```
sudo npm install -g hubot coffee-script yo generator-hubot
```

Finally we can create the Hubot

```
cd /opt/hubot
sudo su - hubot 
yo hubot
```

### Run hubot
```
HUBOT_SLACK_TOKEN=xoxb-1234-5678-91011-00e4dd ./bin/hubot --adapter slack
```

Jump onto slack and invite hubot into general. Confirm it works by typing **@hubot help**  
You can run Hubot in the background using the likes of `tmux` or `screen`. Alternitively, you could run it as a daemon, however, I haven't had any luck with that.