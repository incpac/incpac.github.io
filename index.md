---
layout: page
title:  about
---

<quote class="header">Hey, guess what you're accessories to</quote>  
  
My name is Thomas. I'm an engineer. I'm a tinkerer. I'm a destroy, a warranty voider, a creator.  
  
This site is a place where I take notes on whatever I'm working with at the time.

## posts
<ul class="posts">
  {% for post in site.categories.words %}
    <li>{{ post.date || date: "%Y/%m/%d" }} >> <a href="{{ post.url }}">{{ post.title }}</a></li>
  {% endfor %}
</ul>
