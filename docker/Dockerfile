FROM composer:2 AS vendor

WORKDIR /var/www/html

ARG INSTALL_DEV_DEPENDENCIES=false

COPY composer.json composer.lock ./
RUN if [ "$INSTALL_DEV_DEPENDENCIES" = "true" ]; then \
    composer install --no-interaction --prefer-dist --optimize-autoloader --no-scripts --ignore-platform-reqs; \
    else \
    composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader --no-scripts --ignore-platform-reqs; \
    fi


FROM php:8.4-cli-alpine AS assets

WORKDIR /var/www/html

ARG VITE_REVERB_APP_KEY=local-key
ARG VITE_REVERB_HOST=localhost
ARG VITE_REVERB_PORT=8080
ARG VITE_REVERB_SCHEME=http

ENV VITE_REVERB_APP_KEY=${VITE_REVERB_APP_KEY}
ENV VITE_REVERB_HOST=${VITE_REVERB_HOST}
ENV VITE_REVERB_PORT=${VITE_REVERB_PORT}
ENV VITE_REVERB_SCHEME=${VITE_REVERB_SCHEME}

RUN retry() { \
        attempts=$1; \
        shift; \
        count=1; \
        while [ "$count" -le "$attempts" ]; do \
            "$@" && return 0; \
            if [ "$count" -eq "$attempts" ]; then \
                return 1; \
            fi; \
            count=$((count + 1)); \
            sleep 5; \
        done; \
    }; \
    retry 3 apk add --no-cache nodejs npm

COPY package.json package-lock.json ./

RUN retry() { \
        attempts=$1; \
        shift; \
        count=1; \
        while [ "$count" -le "$attempts" ]; do \
            "$@" && return 0; \
            if [ "$count" -eq "$attempts" ]; then \
                return 1; \
            fi; \
            count=$((count + 1)); \
            sleep 5; \
        done; \
    }; \
    retry 3 npm ci

COPY . .
COPY --from=vendor /var/www/html/vendor ./vendor

RUN npm run build


FROM php:8.4-fpm-alpine AS app

WORKDIR /var/www/html

RUN retry() { \
        attempts=$1; \
        shift; \
        count=1; \
        while [ "$count" -le "$attempts" ]; do \
            "$@" && return 0; \
            if [ "$count" -eq "$attempts" ]; then \
                return 1; \
            fi; \
            count=$((count + 1)); \
            sleep 5; \
        done; \
    }; \
    retry 3 sh -c 'apk add --no-cache fcgi postgresql-client postgresql-dev icu-dev libzip-dev && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS' \
    && docker-php-ext-install pdo_mysql pdo_pgsql bcmath pcntl intl zip \
    && apk del .build-deps

COPY . .
COPY --from=vendor /var/www/html/vendor ./vendor
COPY --from=assets /var/www/html/public/build ./public/build
COPY docker/start-container.sh /usr/local/bin/start-container

RUN chmod +x /usr/local/bin/start-container \
    && rm -f public/hot \
    && mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache public

USER www-data

ENTRYPOINT ["/usr/local/bin/start-container"]
CMD ["php-fpm", "-F"]


FROM nginx:1.27-alpine AS web

WORKDIR /var/www/html

COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY public ./public
COPY --from=assets /var/www/html/public/build ./public/build

RUN rm -f /var/www/html/public/hot \
    && ln -s /var/www/html/storage/app/public /var/www/html/public/storage
