FROM postgres:17-alpine
RUN apk add --no-cache bash curl jq tar coreutils
COPY agent.sh /agent.sh
RUN chmod +x /agent.sh
ENTRYPOINT ["/agent.sh"]