FROM alpine:3.19

RUN apk add --no-cache bash curl && \
    curl -LO "https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/kubectl

COPY pod-access-check.sh /usr/local/bin/pod-access-check.sh
RUN chmod +x /usr/local/bin/pod-access-check.sh

ENTRYPOINT ["/usr/local/bin/pod-access-check.sh"]
