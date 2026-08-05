FROM alpine:3.19

RUN apk add --no-cache bash redis

COPY redis-check.sh /usr/local/bin/redis-check.sh
RUN chmod +x /usr/local/bin/redis-check.sh

ENTRYPOINT ["/usr/local/bin/redis-check.sh"]
