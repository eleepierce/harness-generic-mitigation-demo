FROM zookeeper:3.9

# zookeeper:3.9 (unlike its -alpine variant) is Debian-based - apt-get, not apk.
RUN apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*

COPY zk-check.sh /usr/local/bin/zk-check.sh
RUN chmod +x /usr/local/bin/zk-check.sh

COPY mitigation-entrypoint.sh /usr/local/bin/mitigation-entrypoint.sh
RUN chmod +x /usr/local/bin/mitigation-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/mitigation-entrypoint.sh", "/usr/local/bin/zk-check.sh"]
