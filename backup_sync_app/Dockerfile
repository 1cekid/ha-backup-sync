ARG BUILD_FROM=ghcr.io/home-assistant/base:latest
FROM ${BUILD_FROM}

RUN apk add --no-cache openssh-client rsync curl jq

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD ["/run.sh"]
