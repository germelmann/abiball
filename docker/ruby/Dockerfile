FROM ruby:3-alpine

RUN apk update && apk upgrade
RUN apk add --no-cache \
    bash \
    curl \
    build-base \
    imagemagick \
    imagemagick-dev \
    libjpeg-turbo \
    libjpeg-turbo-dev \
    libpng \
    libpng-dev \
    tzdata \
    ruby-dev \
    && rm -rf /var/cache/apk/*

RUN cp /usr/share/zoneinfo/Europe/Berlin /etc/localtime && echo "Europe/Berlin" > /etc/timezone
RUN gem install bundler
ADD Gemfile /
RUN bundle install
USER 1000:1000
