FROM alpine:3.19

RUN apk add --no-cache bash mariadb-client

COPY check.sh /usr/local/bin/check.sh
RUN chmod +x /usr/local/bin/check.sh

ENTRYPOINT ["/usr/local/bin/check.sh"]
