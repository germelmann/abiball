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
    nodejs \
    npm \
    && rm -rf /var/cache/apk/*

RUN cp /usr/share/zoneinfo/Europe/Berlin /etc/localtime && echo "Europe/Berlin" > /etc/timezone
RUN gem install bundler
ADD Gemfile /
RUN bundle install

# pdfme for yearbook template PDF generation
RUN mkdir -p /opt/pdfme
ADD pdfme-package.json /opt/pdfme/package.json
RUN cd /opt/pdfme && npm install --omit=dev --no-audit --no-fund && chmod -R a+rX /opt/pdfme

USER 1000:1000
