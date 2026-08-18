FROM alpine:3.19

RUN apk add --no-cache bash redis jq

COPY redis-check.sh /usr/local/bin/redis-check.sh
RUN chmod +x /usr/local/bin/redis-check.sh

COPY mitigation-entrypoint.sh /usr/local/bin/mitigation-entrypoint.sh
RUN chmod +x /usr/local/bin/mitigation-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/mitigation-entrypoint.sh", "/usr/local/bin/redis-check.sh"]
