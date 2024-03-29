---
layout: single
title: Deploying CircleCI Golange Builds to Github
date: 2019-03-17
---

__Update 13/04/2019:__ I'll be honest, walking into this project I really didn't have a firm grasp on how git tags work as 
I've never used them. I wrote this post while developing the process and it seemed to work, however shortly after I discovered 
I truely have still idea how git tags work. Realizing this, I've determined that my versioning scheme was flawed from the 
start. I was using the number of commits since the last tag to set the build component of the symantec version. That was 
stupid. Probably some subconsious way to stroke my ego and make it look like I work on these projects more than I actually do. 
I had originally planned on simply removing this post, however in the spirit of openess decided to re-add it.

Because of this you should ignore the lines where the VERSION variable is set and come up with your own way to do the version.

__Original Post Begins Here__  
I'm going to be super lazy with this one, this is going to be simple and lacking because I haven't thought too much about what 
I'm doing. I may come back at a later date and clean it up.

## Goal

The ultimate goal I was tring to reach was to have CircleCI build usable binaries everytime I pushed a commit with a version 
tag. This hasn't worked out exactly how I wanted (mostly because I was misunderstanding git tags) however I've gotten 
something somewhat usable.


## Release Process

1. The moment you've had a successful build, bump the version with a `git tag`
2. Write code and commit to a development branch.
3. When you're ready for release, meger to master and push to Github. CircleCI will then build the version and upload as a 
   Github Release.
4. Bump the version in the git tag

This will create a new release on the Releases tab with binaries definied in the CircleCI config.

## CircleCI Config.

```yaml
version: 2  
jobs: 
  build:
    docker:
      - image: circleci/golang:1.9
    working_directory: "$GOPATH/src/github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
    steps:
      - checkout
      - run:
          name: "Get dependencies"
          command: |
            cd "$GOPATH/src/github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
            go get -v
            dep ensure
      - run: 
          name: "Build MacOS x86"
          command: |
            cd "$GOPATH/src/github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
            export VERSION=$(awk -F"-" '{print ""$1"."$2}' <<< $(git describe --long))
            export GOOS=darwin
            export GOARCH=386
            go build -ldflags "-X main.Version=$VERSION" -o "build/${CIRCLE_PROJECT_REPONAME}-$GOOS-$GOARCH"
      - run:
          name: "Build MacOS amd64"
          command: |
            cd "$GOPATH/src/github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
            export VERSION=$(awk -F"-" '{print ""$1"."$2}' <<< $(git describe --long))
            export GOOS=darwin
            export GOARCH=amd64
            go build -ldflags "-X main.Version=$VERSION" -o "build/${CIRCLE_PROJECT_REPONAME}-$GOOS-$GOARCH"
      - run:
          name: "Build Linux x86"
          command: |
            cd "$GOPATH/src/github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
            export VERSION=$(awk -F"-" '{print ""$1"."$2}' <<< $(git describe --long))
            export GOOS=linux
            export GOARCH=386
            go build -ldflags "-X main.Version=$VERSION" -o "build/${CIRCLE_PROJECT_REPONAME}-$GOOS-$GOARCH"
      - run:
          name: "Build Linux amd64"
          command: |
            cd "$GOPATH/src/github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
            export VERSION=$(awk -F"-" '{print ""$1"."$2}' <<< $(git describe --long))
            export GOOS=linux
            export GOARCH=amd64
            go build -ldflags "-X main.Version=$VERSION" -o "build/${CIRCLE_PROJECT_REPONAME}-$GOOS-$GOARCH"
      - run:
          name: "Build Windows x86"
          command: |
            cd "$GOPATH/src/github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
            export VERSION=$(awk -F"-" '{print ""$1"."$2}' <<< $(git describe --long))
            export GOOS=windows
            export GOARCH=386
            go build -ldflags "-X main.Version=$VERSION" -o "build/${CIRCLE_PROJECT_REPONAME}-$GOOS-$GOARCH"
      - run:
          name: "Build Windows amd64"
          command: |
            cd "$GOPATH/src/github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
            export VERSION=$(awk -F"-" '{print ""$1"."$2}' <<< $(git describe --long))
            export GOOS=windows
            export GOARCH=amd64
            go build -ldflags "-X main.Version=$VERSION" -o "build/${CIRCLE_PROJECT_REPONAME}-$GOOS-$GOARCH"
      - run:
          name: "Publish release to Github"
          command: |
            cd "$GOPATH/src/github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
            go get github.com/tcnksm/ghr
            export VERSION=$(awk -F"-" '{print ""$1"."$2}' <<< $(git describe --long))
            ghr -t ${GITHUB_TOKEN} -u ${CIRCLE_PROJECT_USERNAME} -r ${CIRCLE_PROJECT_REPONAME} -c ${CIRCLE_SHA1} -delete $VERSION ./build/
```
