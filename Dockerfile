FROM debian:wheezy
MAINTAINER Paul van Tilburg "paul@luon.net"

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
  camping \
  ruby-activerecord-3.2 \
  ruby-sqlite3 \
  ruby-mab \
  ruby-actionpack-3.2 \
  ruby-sass \
  thin \
  texlive-latex-base \
  texlive-latex-extra \
  rubber

RUN mkdir -p /home/camping/stoptime
ADD . /home/camping/stoptime
WORKDIR /home/camping/stoptime
ENV HOME /home/camping

# Ugh, necessary because not available in backports
# Before build on Jessie/Sid: apt-get download ruby-mab
RUN dpkg -i ruby-mab_0.0.3-1_all.deb

RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

EXPOSE 3301
CMD    ["/usr/bin/camping", "stoptime.rb"]
