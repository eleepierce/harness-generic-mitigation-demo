FROM zookeeper:3.9

COPY zk-check.sh /usr/local/bin/zk-check.sh
RUN chmod +x /usr/local/bin/zk-check.sh

ENTRYPOINT ["/usr/local/bin/zk-check.sh"]
