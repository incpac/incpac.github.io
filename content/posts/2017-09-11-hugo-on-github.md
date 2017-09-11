+++
date = "2017-09-11T19:23:50+12:00"
title = "Hugo on Github"
+++

I'll admit I have a motivation problem. I have real trouble seeing something through in a timely manor. I only started working on the second prototype of my midi controller last weekend. Version one was complete 10 months ago. I had the idea for it 14 months before that. Hell the subject of this post was finalised and implemented a month ago. I'm starting this post on the 11th but it's probably gonna be a few days before it actually gets published.

I suppose, for the blog at least, one of the issues is I want to write more than just the technical steps. I see other blogs with long prefaces going into why they did this and that. A lot of this doesn't apply to me; I simply like building shit. I think the problem lies in the fact that when you do a lot of technical shit as your day job, the last thing you want to do is come home and do more technical shit.

Whatever. I told you I'm bad at this and now I'm just spewing crap. Let's give the people what they came for.

# Blood!

_Cough_. I mean "Deploying Hugo on Github Pages"

Now, to completely contradict myself, here's a bit of a back story. I like Jekyll. It's easy to use. You can control pretty much anything you want. It's written in Ruby. Don't get me wrong, I love Ruby; but man, fuck Ruby. It's a prick to install; you've got to compile it pretty much every time. Then there's fucking Nokogiri. That thing's a shit show on Ubuntu.

Then along comes Hugo. It's fast, a single binary, I don't have to install it, etc, etc. I only have two issues with it; the way it handles templating and the lack of integration with Github Pages. The first issue I can live with, so I won't go into. However, the Github Pages thing is an issue. With Jekyll you can simply push your source to Github and they'll take care of the rest. With Hugo (an effectively everything not Jekyll) you have to first build your site then push. This means you're running two repositories.

In steps Circle CI. Now I've never actually used any sort of CI/CD before. I understand what they do, sure. But, I've never actually had the need to use one. Until now, at least.

What we're going to do here is have a single repository. Our website will reside in the 'master' branch, and our Hugo source will live in a 'source' branch. We're then going to set up Circle to monitor the source branch for changes, rebuild the site, then push to master.
