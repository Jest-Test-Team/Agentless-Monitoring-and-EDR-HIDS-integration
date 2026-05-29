FROM docker.elastic.co/logstash/logstash:${LOGSTASH_VERSION:-7.17.24}
RUN rm -f /usr/share/logstash/pipeline/default.cfg && \
    /usr/share/logstash/bin/logstash-plugin install logstash-output-opensearch
