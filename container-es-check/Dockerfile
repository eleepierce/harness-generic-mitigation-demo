FROM alpine:3.19

RUN apk add --no-cache bash curl

COPY es-check.sh /usr/local/bin/es-check.sh
RUN chmod +x /usr/local/bin/es-check.sh

ENTRYPOINT ["/usr/local/bin/es-check.sh"]
