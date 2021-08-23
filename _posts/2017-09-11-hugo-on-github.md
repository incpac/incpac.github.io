---
layout: single
title: Hugo on Github
date: 2017-09-11
---

Yea, yea, updates. I have a motivation problem. I have real trouble seeing something through in a timely manner. I only 
started working on the second prototype of my midi controller last weekend. Version one was complete 10 months ago. I had the 
idea for it 14 months before that. Hell, the subject of this post was finalized and implemented a month ago. I'm starting this 
on the 11th but it's probably gonna end up being a couple of weeks before it actually gets published.

I suppose, for the blog at least, one of the issues is I want to write more than just the technical steps. I see other blogs 
with long prefaces going into why they did this and that. A lot of this doesn't apply to me; I simply like building shit.

I think the problem lies in the fact that when you do a lot of technical shit as your day job, the last thing you want to do 
is come home and do more technical shit.

Whatever. I told you I'm bad at this and now I'm just spewing crap. Let's give the people what they came for.

# Blood!

_Cough_. I mean "Deploying Hugo on Github Pages"

To completely contradict myself, here's a bit of a backstory. I like Jekyll. It's easy to use and you can control pretty much 
anything you want. I only really have one issue with it; it's written in Ruby. Now, don't get me wrong, I love Ruby. But man, 
fuck Ruby. It's a prick to install because you've got to compile it pretty much every time. Then there's fucking Nokogiri. 
That thing's a shit show on Ubuntu.

Along comes Hugo. It's fast, a single binary, I don't have to compile it, etc, etc. I only have two issues with it: the way it 
handles templating and the lack of integration with Github Pages. The first one I can live with, so I won't go into. However, 
the Github Pages thing really is an issue. With Jekyll, you can simply push your source to Github and they'll take care of the 
rest. With Hugo (and effectively everything not Jekyll) you have to first build your site then push. This means you're running 
two repositories.

In steps Circle CI. Now I've never actually used any sort of CI/CD before. I understand what they do, sure. But, I've never 
actually had the need to use one. Until now, at least.

What we're going to do here is have a single repository. Our website will reside in the 'master' branch, and our Hugo source 
will live in a 'source' branch. We're then going to set up Circle to monitor the source branch for changes, rebuild the site, 
then push to master.

# Get on with it already

Sweet. Game plan's sorted. First on the list is to set up our Github repo and clone it locally. Now, I'm not going to take 
baby steps with you. If you're here I assume you already know how to do this.

Now, we're going to create an orphaned branch. This is to keep our source branch separate from the master. To do this run

```
git checkout -b --orphan source
```

Slap your site's source in here now, commit, then push the branch to GitHub.

Head over to [Circle CI](https://circleci.com) and sign up. You can use your Github account. On the left-hand side, you'll 
find "Projects". Add a new one, find your Github Pages repo, and hit "Setup project". Our language is "Other". Aside from 
that, all defaults are fine.

You'll get an email from Github stating that a public key has been added to your repo. This allows Circle CI to clone the 
repo. We're going to want to also give it permissions to write.

To do this, go to the "Checkout SSH Keys" and click "Create and add user key". If you browse to your SSH keys on Github you 
should see the one Circle just created. This grants Circle write access to your repos. There is 
[a method](https://circleci.com/docs/2.0/gh-bb-integration/#adding-readwrite-deployment-keys-to-github-or-bitbucket) to only 
grant access to the specific repository, however you can see in the commits just after this post that I couldn't get it to 
work.

In your repo create the config file `.circleci/config.yml` I'm going to dump the entire thing here, then we're going to go 
through it.

```
version: 2
jobs:
  build:
    docker:
      - image: felicianotech/docker-hugo:0.22.1
    branches:
      only:
        - source
    working_directory: ~/source
    steps:
      - checkout
      - run:
          name: "Run Hugo"
          command: HUGO_ENV=production hugo -v -s ~/source/
      - run:
          name: "Test Website"
          command: htmlproofer ~/source/public --allow-hash-href --check-html --empty-alt-ignore
      - run:
          name: "Git Push"
          command: |
            cd ~/source
            remote=$(git config remote.origin.url)

            mkdir ~/build
            cd ~/build

            git config --global user.name "$GH_NAME" > /dev/null 2>&1
            git config --global user.email "$GH_EMAIL" > /dev/null 2>&1

            git init
            git remote add --fetch origin "$remote"
            git pull origin master

            git rm -rf .

            cp -r ~/source/public/* .

            git add -A
            git commit --allow-empty -m "deploy to github pages [ci step]"
            git push --force --quiet origin master > /dev/null 2>&1
```

And, here we go.

```
version: 2
jobs:
  build:
```

Basic building blocks. Says we have a config file matching the version two standards and we have a build job. Next.

```
    docker:
      - image: felicianotech/docker-hugo:0.22.1
```

We want to use the `felicianotech/docker-hugo:0.22.1` docker image. [Felicianotech](https://hub.docker.com/u/felicianotech/) 
has been kind enough to create an image for building hugo sites on Circle. Cheers mate.

```
    branches:
      only:
        - source
```

We only want it to build on changes made to the source branch. Sweet as.

```
    working_directory: ~/source
```

We're going to work out of the `~/source` directory in the container.

```
    steps:
      - checkout
```

This here is where we start to list our build steps. The first is to checkout the repo.

```
      - run:
          name: "Run Hugo"
          command: HUGO_ENV=production hugo -v -s ~/source/
```

Next up is to build the site.

```
      - run:
          name: "Test Website"
          command: htmlproofer ~/source/public --allow-hash-href --check-html --empty-alt-ignore
```

Some basic HTML sanity checks. Remove it if you want.

```
      - run:
          name: "Git Push"
          command: |
```

Now, this is where the fun starts.

```
            cd ~/source
            remote=$(git config remote.origin.url)

            mkdir ~/build
            cd ~/build

            git config --global user.name "$GH_NAME" > /dev/null 2>&1
            git config --global user.email "$GH_EMAIL" > /dev/null 2>&1
```

We move into the source directory so we can get the repo URL. Then we create a dedicated build directory. Following this, 
basic git configuration. This reminds me, we need to set the environment variables up. We'll come back to that.

```
            git init
            git remote add --fetch origin "$remote"
            git pull origin master
```

Create a new git repo, add our Github project as the source, then pull master.

```
            git rm -rf .
```

Clean up the repo. Hugo doesn't clean the build directory first in case you've intentionally put something there, so we need 
to do it ourselves.

```
            cp -r ~/source/public/* .

            git add -A
            git commit --allow-empty -m "deploy to github pages [ci step]"
            git push --force --quiet origin master > /dev/null 2>&1
```

Copy our current build then push to the master branch.

Yes, yes, I remember. The environment variables. In the Circle CI settings, there's a handy tab called "Environment 
Variables". This is a handy way to get configs/secrets into your build without having to include it in your repo. We want one 
named `GH_EMAIL` and another named `GH_NAME`.

Excellent, with all that set up we should be good to commit the config file and make one last push to Github. You should then 
be able to see the progress in the Circle dashboard. Any issues should also show up here.

And we're done. You should be all good from this point.

It's now the 23rd. Twelve days after I started. Shit.

Whatever.
